/**
 * @name iniciar-conversa
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-27
 * 
 * @description
 * Gerencia início de conversas com sistema de avaliação inteligente.
 * Analisa atividade do aluno e envia feedback apropriado antes de criar conversation.
 * 
 * @workflow
 * 1. Busca dados do aluno (tem_avaliacao_pendente, data_ultima_avaliacao, avaliacao_pendente_texto)
 * 2. Aplica lógica de feedback:
 *    - 1 dia: Envia avaliação gerada pela LLM durante a noite
 *    - 2-6 dias: Mensagem estática + última avaliação
 *    - 7+ dias: [IMPLEMENTAR DEPOIS]
 * 3. Cria conversation na OpenAI
 * 4. Salva conversation_id no banco
 * 5. Chama orquestrador para processar mensagem original
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
    const { aluno_id, mensagem_id } = await req.json();
    console.log('[IniciarConversa] 🚀 Iniciando para aluno:', aluno_id);
    if (!aluno_id || !mensagem_id) {
      throw new Error("'aluno_id' e 'mensagem_id' são obrigatórios");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. BUSCAR DADOS DO ALUNO
    // ============================================
    console.log('[IniciarConversa] 1. Buscando dados do aluno...');
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('tem_avaliacao_pendente, data_ultima_avaliacao, avaliacao_pendente_texto').eq('id', aluno_id).single();
    if (alunoError) {
      throw new Error(`Erro ao buscar aluno: ${alunoError.message}`);
    }
    const { tem_avaliacao_pendente, data_ultima_avaliacao, avaliacao_pendente_texto } = alunoData;
    console.log('[IniciarConversa] ✅ tem_avaliacao_pendente:', tem_avaliacao_pendente);
    console.log('[IniciarConversa] ✅ data_ultima_avaliacao:', data_ultima_avaliacao);
    // ============================================
    // 2. LÓGICA DE FEEDBACK
    // ============================================
    let mensagemFeedback = null;
    if (tem_avaliacao_pendente && data_ultima_avaliacao && avaliacao_pendente_texto) {
      const hoje = new Date();
      hoje.setHours(0, 0, 0, 0); // Zera horas para comparação precisa
      const dataAvaliacao = new Date(data_ultima_avaliacao);
      dataAvaliacao.setHours(0, 0, 0, 0);
      const diasDiferenca = Math.floor((hoje.getTime() - dataAvaliacao.getTime()) / (1000 * 60 * 60 * 24));
      console.log('[IniciarConversa] 📅 Dias desde última avaliação:', diasDiferenca);
      // CASO 1: Ativo regular (1 dia)
      if (diasDiferenca === 1) {
        console.log('[IniciarConversa] ✅ CASO 1: Ativo regular');
        mensagemFeedback = avaliacao_pendente_texto;
        // Limpa flag
        await supabase.from('alunos').update({
          tem_avaliacao_pendente: false
        }).eq('id', aluno_id);
        console.log('[IniciarConversa] ✅ Flag limpa');
      } else if (diasDiferenca >= 2 && diasDiferenca <= 6) {
        console.log('[IniciarConversa] ⚠️ CASO 2: Abandono leve');
        const dataFormatada = dataAvaliacao.toLocaleDateString('pt-BR', {
          day: '2-digit',
          month: '2-digit',
          year: 'numeric'
        });
        mensagemFeedback = `💙 *Sentimos sua falta!*\n\n` + `Faz ${diasDiferenca} ${diasDiferenca === 2 ? 'dia' : 'dias'} que não nos falamos. ` + `Lembre-se: *a consistência é a chave para alcançar seus objetivos!*\n\n` + `📊 *Sua última avaliação em ${dataFormatada} foi:*\n\n` + `${avaliacao_pendente_texto}`;
        // Limpa flag
        await supabase.from('alunos').update({
          tem_avaliacao_pendente: false
        }).eq('id', aluno_id);
        console.log('[IniciarConversa] ✅ Flag limpa');
      } else if (diasDiferenca >= 7) {
        console.log('[IniciarConversa] 🚨 CASO 3: Abandono severo - IMPLEMENTAR DEPOIS');
      // TODO: Implementar chamada LLM motivacional
      }
    } else {
      console.log('[IniciarConversa] ℹ️ Sem avaliação pendente ou dados incompletos');
    }
    // ============================================
    // 3. ENVIAR FEEDBACK (SE HOUVER)
    // ============================================
    if (mensagemFeedback) {
      console.log('[IniciarConversa] 📤 Enviando feedback...');
      console.log('[IniciarConversa] 📝 Preview:', mensagemFeedback.substring(0, 100) + '...');
      const { error: envioError } = await supabase.functions.invoke('enviar_menssagem_whatsapp', {
        body: {
          aluno_id: aluno_id,
          mensagem: mensagemFeedback
        }
      });
      if (envioError) {
        console.error('[IniciarConversa] ❌ Erro ao enviar feedback:', envioError);
      // Não interrompe o fluxo - continua mesmo se falhar
      } else {
        console.log('[IniciarConversa] ✅ Feedback enviado com sucesso');
      }
    }
    // ============================================
    // 4. CRIAR CONVERSATION NA OPENAI
    // ============================================
    console.log('[IniciarConversa] 4. Criando conversation...');
    const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        metadata: {
          aluno_id: aluno_id,
          tipo: 'coaching_nutricional'
        }
      })
    });
    if (!createConvResponse.ok) {
      const errorText = await createConvResponse.text();
      throw new Error(`Erro ao criar conversation: ${errorText}`);
    }
    const convData = await createConvResponse.json();
    const conversation_id = convData.id;
    console.log('[IniciarConversa] ✅ Conversation criada:', conversation_id);
    // ============================================
    // 5. SALVAR CONVERSATION_ID NO BANCO
    // ============================================
    const { error: updateError } = await supabase.from('dynamic_prompts').update({
      conversation_id: conversation_id
    }).eq('aluno_id', aluno_id);
    if (updateError) {
      throw new Error(`Erro ao salvar conversation_id: ${updateError.message}`);
    }
    console.log('[IniciarConversa] ✅ Conversation_id salvo no banco');
    // ============================================
    // 6. CHAMAR ORQUESTRADOR PARA PROCESSAR MENSAGEM
    // ============================================
    console.log('[IniciarConversa] 🔄 Chamando orquestrador...');
    const { error: orquestradorError } = await supabase.functions.invoke('orquestrador-ia', {
      body: {
        mensagem_id
      }
    });
    if (orquestradorError) {
      throw new Error(`Erro ao chamar orquestrador: ${orquestradorError.message}`);
    }
    console.log('[IniciarConversa] ✅ CONCLUÍDO');
    return new Response(JSON.stringify({
      success: true,
      conversation_id,
      feedback_enviado: !!mensagemFeedback,
      dias_inatividade: tem_avaliacao_pendente && data_ultima_avaliacao ? Math.floor((new Date().getTime() - new Date(data_ultima_avaliacao).getTime()) / (1000 * 60 * 60 * 24)) : 0
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[IniciarConversa] ❌ ERRO:', error.message);
    console.error('[IniciarConversa] Stack:', error.stack);
    return new Response(JSON.stringify({
      error: error.message,
      stack: error.stack
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 500
    });
  }
});
