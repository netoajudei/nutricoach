/**
 * @name finalizar-update-carga
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-05 01:30:00 -03:00
 * 
 * @description
 * Edge Function que finaliza atualização de carga (confirmação ou cancelamento).
 * Recebe botao_id e confirmado, busca dados do botão e executa ação apropriada.
 * 
 * @param {string} botao_id - ID do botão ativo
 * @param {boolean} confirmado - true = confirmar, false = cancelar
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    console.log('[FINALIZAR CARGA] 🚀 Iniciando');
    const { botao_id, confirmado } = await req.json();
    // ========================================
    // VALIDAÇÕES
    // ========================================
    if (!botao_id || confirmado === undefined) {
      throw new Error('Parâmetros obrigatórios: botao_id e confirmado');
    }
    console.log('[FINALIZAR CARGA] 📋 Botão ID:', botao_id);
    console.log('[FINALIZAR CARGA] 📋 Confirmado:', confirmado);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR BOTÃO NO BANCO
    // ========================================
    console.log('[FINALIZAR CARGA] 🔍 Buscando botão...');
    const { data: botao, error: botaoError } = await supabase.from('botoes_ativos').select('*').eq('id', botao_id).single();
    if (botaoError || !botao) {
      throw new Error('Botão não encontrado');
    }
    console.log('[FINALIZAR CARGA] ✅ Botão encontrado');
    console.log('[FINALIZAR CARGA] 👤 Aluno ID:', botao.aluno_id);
    console.log('[FINALIZAR CARGA] 🔧 Tipo:', botao.tipo_acao);
    const { aluno_id, conversation_id, tool_call_id, argumentos } = botao;
    const { exercicio_id, nova_carga, carga_atual, nome_exercicio, whatsapp } = argumentos;
    // ========================================
    // ROTA POSITIVA: CONFIRMAR ATUALIZAÇÃO
    // ========================================
    if (confirmado) {
      console.log('[FINALIZAR CARGA] ✅ CONFIRMADO - Atualizando carga...');
      // 1. Atualizar carga no banco
      const { error: updateError } = await supabase.from('workout_exercises').update({
        carga_kg: nova_carga,
        updated_at: new Date().toISOString()
      }).eq('id', exercicio_id);
      if (updateError) {
        throw new Error(`Erro ao atualizar carga: ${updateError.message}`);
      }
      console.log('[FINALIZAR CARGA] ✅ Carga atualizada:', nova_carga, 'kg');
      // 2. Registrar auditoria (opcional)
      const { error: auditError } = await supabase.from('historico_atualizacoes_exercicio').insert({
        aluno_id: aluno_id,
        exercicio_id: exercicio_id,
        carga_anterior: carga_atual,
        carga_nova: nova_carga,
        tipo_mudanca: 'botao_confirmacao',
        timestamp: new Date().toISOString()
      });
      if (auditError) {
        console.warn('[FINALIZAR CARGA] ⚠️ Erro ao registrar auditoria (não crítico)');
      }
      // 3. Mensagem de sucesso
      const mensagemSucesso = `✅ Ótimo! Sua carga foi atualizada com sucesso!

*${nome_exercicio}*
${carga_atual}kg → *${nova_carga}kg* 💪

Vamos lá! Essa carga extra vai fazer você ficar ainda mais forte nos próximos treinos! 🚀`;
      // 4. Finalizar function calling na OpenAI
      console.log('[FINALIZAR CARGA] 🔄 Finalizando function calling...');
      const openaiPayload = {
        conversation: conversation_id,
        type: 'function_call_output',
        call_id: tool_call_id,
        output: JSON.stringify({
          success: true,
          exercicio: nome_exercicio,
          carga_anterior: carga_atual,
          carga_nova: nova_carga,
          mensagem: mensagemSucesso
        })
      };
      const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(openaiPayload)
      });
      if (!openaiResponse.ok) {
        const errorText = await openaiResponse.text();
        throw new Error(`Erro ao finalizar function calling: ${errorText}`);
      }
      const responseData = await openaiResponse.json();
      console.log('[FINALIZAR CARGA] ✅ Function calling finalizado');
      // 5. Extrair resposta da IA
      let respostaIA = '';
      for (const item of responseData.output || []){
        if (item.type === 'message' && item.role === 'assistant') {
          const textContent = item.content?.find((c)=>c.type === 'output_text');
          if (textContent) {
            respostaIA = textContent.text;
            break;
          }
        }
      }
      // 6. Enviar resposta ao usuário
      const { data: configData } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
      if (configData) {
        const mensagemFinal = respostaIA || mensagemSucesso;
        await fetch(`https://us.api-wa.me/${configData.valor}/message/text`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            to: whatsapp,
            text: mensagemFinal
          })
        });
        console.log('[FINALIZAR CARGA] ✅ Mensagem enviada ao usuário');
      }
    // ========================================
    // ROTA NEGATIVA: CANCELAR ATUALIZAÇÃO
    // ========================================
    } else {
      console.log('[FINALIZAR CARGA] ❌ CANCELADO - Mantendo carga atual...');
      // 1. Finalizar function calling na OpenAI
      console.log('[FINALIZAR CARGA] 🔄 Finalizando function calling (cancelado)...');
      const openaiPayload = {
        conversation: conversation_id,
        type: 'function_call_output',
        call_id: tool_call_id,
        output: JSON.stringify({
          success: false,
          cancelled: true,
          mensagem: 'Usuário optou por não atualizar a carga'
        })
      };
      const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(openaiPayload)
      });
      if (!openaiResponse.ok) {
        const errorText = await openaiResponse.text();
        throw new Error(`Erro ao finalizar function calling: ${errorText}`);
      }
      const responseData = await openaiResponse.json();
      console.log('[FINALIZAR CARGA] ✅ Function calling finalizado (cancelado)');
      // 2. Extrair resposta da IA
      let respostaIA = '';
      for (const item of responseData.output || []){
        if (item.type === 'message' && item.role === 'assistant') {
          const textContent = item.content?.find((c)=>c.type === 'output_text');
          if (textContent) {
            respostaIA = textContent.text;
            break;
          }
        }
      }
      // 3. Enviar resposta ao usuário
      const { data: configData } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
      if (configData) {
        const mensagemCancelamento = respostaIA || `Ok! Mantive a carga atual de ${carga_atual}kg para ${nome_exercicio}. 

Como posso te ajudar agora? 😊`;
        await fetch(`https://us.api-wa.me/${configData.valor}/message/text`, {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            to: whatsapp,
            text: mensagemCancelamento
          })
        });
        console.log('[FINALIZAR CARGA] ✅ Mensagem de cancelamento enviada');
      }
    }
    // ========================================
    // DELETAR BOTÃO DO BANCO
    // ========================================
    console.log('[FINALIZAR CARGA] 🗑️ Deletando botão...');
    const { error: deleteError } = await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    if (deleteError) {
      console.warn('[FINALIZAR CARGA] ⚠️ Erro ao deletar botão (não crítico)');
    } else {
      console.log('[FINALIZAR CARGA] ✅ Botão deletado');
    }
    // ========================================
    // RETORNAR SUCESSO
    // ========================================
    return new Response(JSON.stringify({
      success: true,
      confirmado: confirmado,
      message: confirmado ? 'Carga atualizada com sucesso' : 'Atualização de carga cancelada'
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[FINALIZAR CARGA] ❌ ERRO:', error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  }
});
