/**
 * @name cron-gerar-avaliacoes
 * @version 1.0.0
 * @description Gera avaliações diárias via LLM para alunos ativos
 * @schedule 02:05 AM diariamente (5 min após preparar-avaliacoes)
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    console.log('[CronGerarAvaliacoes] 🚀 Iniciando geração de avaliações');
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const ontem = new Date();
    ontem.setDate(ontem.getDate() - 1);
    const dataOntem = ontem.toISOString().split('T')[0];
    const { data: alunos, error: alunosError } = await supabase.from('alunos').select('id, nome_completo');
    if (alunosError) {
      throw new Error(`Erro ao buscar alunos: ${alunosError.message}`);
    }
    console.log(`[CronGerarAvaliacoes] 📊 Total de alunos: ${alunos.length}`);
    const { data: promptData, error: promptError } = await supabase.from('prompts_sistema').select('prompt_final').eq('chave', 'prompt_avaliacao_diaria').single();
    if (promptError || !promptData) {
      throw new Error('Prompt de avaliação não encontrado');
    }
    const promptBase = promptData.prompt_final;
    console.log('[CronGerarAvaliacoes] ✅ Prompt carregado');
    let processados = 0;
    let avaliacoes_geradas = 0;
    let erros = 0;
    for (const aluno of alunos){
      try {
        console.log(`[CronGerarAvaliacoes] 🔄 Processando: ${aluno.nome_completo}`);
        const { data: dynamicData, error: dynamicError } = await supabase.from('dynamic_prompts').select('conquistas_recentes_md').eq('aluno_id', aluno.id).single();
        if (dynamicError) {
          console.log(`[CronGerarAvaliacoes] ⚠️ ${aluno.nome_completo} - sem dynamic_prompts`);
          processados++;
          continue;
        }
        const conquistasMarkdown = dynamicData.conquistas_recentes_md;
        // VERIFICA SE ESTÁ PREENCHIDO (Aluno ativo)
        if (conquistasMarkdown && conquistasMarkdown.trim().length > 0) {
          console.log(`[CronGerarAvaliacoes] ✅ ${aluno.nome_completo} - ATIVO, gerando avaliação`);
          const promptCompleto = `${promptBase}\n\n# CONTEXTO DO ALUNO:\n${conquistasMarkdown}`;
          const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${OPENAI_API_KEY}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              model: 'gpt-5-mini',
              input: promptCompleto
            })
          });
          if (!openaiResponse.ok) {
            const errorText = await openaiResponse.text();
            throw new Error(`OpenAI error: ${errorText}`);
          }
          const openaiData = await openaiResponse.json();
          let avaliacaoTexto = '';
          for (const item of openaiData.output || []){
            if (item.type === 'message' && item.role === 'assistant') {
              const textContent = item.content?.find((c)=>c.type === 'output_text');
              if (textContent) {
                avaliacaoTexto = textContent.text;
                break;
              }
            }
          }
          if (!avaliacaoTexto) {
            throw new Error('Resposta vazia da IA');
          }
          console.log(`[CronGerarAvaliacoes] 💬 Avaliação gerada (${avaliacaoTexto.length} chars)`);
          const { error: updateError } = await supabase.from('alunos').update({
            avaliacao_pendente_texto: avaliacaoTexto,
            data_ultima_avaliacao: dataOntem,
            tem_avaliacao_pendente: true
          }).eq('id', aluno.id);
          if (updateError) {
            throw new Error(`Erro ao salvar avaliação: ${updateError.message}`);
          }
          avaliacoes_geradas++;
          console.log(`[CronGerarAvaliacoes] ✅ ${aluno.nome_completo} - Avaliação salva`);
        } else {
          // Aluno INATIVO
          console.log(`[CronGerarAvaliacoes] ⚠️ ${aluno.nome_completo} - INATIVO`);
          const { data: statusData, error: statusError } = await supabase.from('alunos').select('tem_avaliacao_pendente').eq('id', aluno.id).single();
          if (statusError) {
            console.error(`[CronGerarAvaliacoes] ❌ Erro ao buscar status: ${statusError.message}`);
            processados++;
            continue;
          }
          if (statusData.tem_avaliacao_pendente) {
            console.log(`[CronGerarAvaliacoes] 🔕 ${aluno.nome_completo} - Já tem avaliação pendente, pulando`);
            processados++;
            continue;
          }
          console.log(`[CronGerarAvaliacoes] 📢 ${aluno.nome_completo} - Gerando aviso de inatividade`);
          const promptInatividade = `${promptBase}

# SITUAÇÃO DO ALUNO:
O aluno ${aluno.nome_completo} NÃO registrou treinos nem alimentação ontem.

Crie uma mensagem CURTA (máximo 5 linhas) motivacional e gentil lembrando da importância dos registros para acompanhar o progresso e alcançar os objetivos.

Use tom empático e encorajador, não punitivo. Formato WhatsApp com *negrito* e emojis.`;
          const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
            method: 'POST',
            headers: {
              'Authorization': `Bearer ${OPENAI_API_KEY}`,
              'Content-Type': 'application/json'
            },
            body: JSON.stringify({
              model: 'gpt-5-mini',
              input: promptInatividade
            })
          });
          if (!openaiResponse.ok) {
            const errorText = await openaiResponse.text();
            throw new Error(`OpenAI error: ${errorText}`);
          }
          const openaiData = await openaiResponse.json();
          let avisoTexto = '';
          for (const item of openaiData.output || []){
            if (item.type === 'message' && item.role === 'assistant') {
              const textContent = item.content?.find((c)=>c.type === 'output_text');
              if (textContent) {
                avisoTexto = textContent.text;
                break;
              }
            }
          }
          if (!avisoTexto) {
            throw new Error('Resposta vazia da IA');
          }
          console.log(`[CronGerarAvaliacoes] 💬 Aviso gerado (${avisoTexto.length} chars)`);
          const { error: updateError } = await supabase.from('alunos').update({
            avaliacao_pendente_texto: avisoTexto,
            tem_avaliacao_pendente: true
          }).eq('id', aluno.id);
          if (updateError) {
            throw new Error(`Erro ao salvar aviso: ${updateError.message}`);
          }
          avaliacoes_geradas++;
          console.log(`[CronGerarAvaliacoes] ✅ ${aluno.nome_completo} - Aviso salvo`);
        }
        processados++;
      } catch (error) {
        console.error(`[CronGerarAvaliacoes] ❌ Erro em ${aluno.nome_completo}:`, error.message);
        erros++;
      }
    }
    console.log(`[CronGerarAvaliacoes] ✅ CONCLUÍDO`);
    console.log(`[CronGerarAvaliacoes] 📊 Processados: ${processados}/${alunos.length}`);
    console.log(`[CronGerarAvaliacoes] 📝 Avaliações geradas: ${avaliacoes_geradas}`);
    console.log(`[CronGerarAvaliacoes] ❌ Erros: ${erros}`);
    return new Response(JSON.stringify({
      success: true,
      total_alunos: alunos.length,
      processados,
      avaliacoes_geradas,
      erros,
      timestamp: new Date().toISOString()
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[CronGerarAvaliacoes] ❌ ERRO CRÍTICO:', error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 500
    });
  }
});
