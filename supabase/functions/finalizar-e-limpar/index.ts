/**
 * @name finalizar-e-limpar
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 15:45:00 -03:00
 * 
 * @description
 * Edge Function GENÉRICA para finalizar function calling com SUCESSO.
 * Finaliza o function calling na OpenAI informando sucesso,
 * obtém uma resposta contextual da IA para enviar ao usuário,
 * envia ao WhatsApp e limpa o bloqueio.
 * 
 * @workflow
 * 1. Recebe aluno_id, whatsapp, conversation_id, tool_call_id, mensagem_sucesso
 * 2. Finaliza function calling na OpenAI com status de sucesso
 * 3. Obtém resposta contextual da IA
 * 4. Envia resposta ao usuário via WhatsApp
 * 5. Limpa bloqueio (aguardando_confirmacao = NULL)
 * 6. Retorna sucesso
 * 
 * @usage
 * Esta função é genérica e serve para:
 * - confirmar_registro_refeicao
 * - confirmar_update_carga
 * - qualquer outra ação que precise ser finalizada com sucesso
 * 
 * @param {string} aluno_id - ID do aluno
 * @param {string} whatsapp - Número WhatsApp do aluno
 * @param {string} conversation_id - ID da conversation OpenAI
 * @param {string} tool_call_id - ID do tool call a ser finalizado
 * @param {string} mensagem_sucesso - Mensagem de sucesso a ser enviada para a IA
 * 
 * @returns {object} { success, message, resposta_enviada }
 * 
 * @security
 * - Usa SUPABASE_SERVICE_ROLE_KEY
 * - Usa OPENAI_API_KEY
 * 
 * @dependencies
 * - OpenAI Responses API
 * - Edge Function: enviar_menssagem_whatsapp
 * - Tabela: alunos
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') || 'gpt-4o-mini';
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    console.log('[FINALIZAR E LIMPAR] 🚀 Iniciando');
    const { aluno_id, whatsapp, conversation_id, tool_call_id, mensagem_sucesso } = await req.json();
    if (!aluno_id || !whatsapp || !conversation_id || !tool_call_id || !mensagem_sucesso) {
      throw new Error('Parâmetros obrigatórios faltando');
    }
    console.log('[FINALIZAR E LIMPAR] 📋 Dados recebidos:');
    console.log('[FINALIZAR E LIMPAR] - Aluno ID:', aluno_id);
    console.log('[FINALIZAR E LIMPAR] - Conversation ID:', conversation_id);
    console.log('[FINALIZAR E LIMPAR] - Tool Call ID:', tool_call_id);
    console.log('[FINALIZAR E LIMPAR] - Mensagem:', mensagem_sucesso.substring(0, 50));
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. FINALIZAR FUNCTION CALLING NA OPENAI
    // ============================================
    console.log('[FINALIZAR E LIMPAR] 🔄 Finalizando function calling...');
    const openaiPayload = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      tool_choice: "none",
      input: [
        {
          type: "function_call_output",
          call_id: tool_call_id,
          output: JSON.stringify({
            status: "Sucesso",
            message: mensagem_sucesso
          })
        }
      ]
    };
    console.log('[FINALIZAR E LIMPAR] 📤 Enviando para OpenAI...');
    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(openaiPayload)
    });
    if (!openaiResponse.ok) {
      const errorText = await openaiResponse.text();
      throw new Error(`Erro OpenAI: ${errorText}`);
    }
    const openaiData = await openaiResponse.json();
    console.log('[FINALIZAR E LIMPAR] ✅ Function calling finalizado');
    console.log('[FINALIZAR E LIMPAR] 📊 Response ID:', openaiData.id);
    // ============================================
    // 2. EXTRAIR RESPOSTA DA IA
    // ============================================
    let respostaIA = '';
    for (const item of openaiData.output || []){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) {
      console.warn('[FINALIZAR E LIMPAR] ⚠️ Resposta vazia da IA, usando mensagem de sucesso');
      respostaIA = mensagem_sucesso;
    }
    console.log('[FINALIZAR E LIMPAR] 💬 Resposta:', respostaIA.substring(0, 100));
    // ============================================
    // 3. ENVIAR RESPOSTA AO USUÁRIO
    // ============================================
    console.log('[FINALIZAR E LIMPAR] 📱 Enviando mensagem ao usuário...');
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
    console.log('[FINALIZAR E LIMPAR] ✅ Mensagem enviada');
    // ============================================
    // 4. LIMPAR BLOQUEIO
    // ============================================
    console.log('[FINALIZAR E LIMPAR] 🔓 Limpando bloqueio...');
    await supabase.from('alunos').update({
      aguardando_confirmacao: null
    }).eq('id', aluno_id);
    console.log('[FINALIZAR E LIMPAR] ✅ Bloqueio removido');
    // ============================================
    // 5. RETORNAR SUCESSO
    // ============================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Function calling finalizado e bloqueio removido',
      resposta_enviada: respostaIA
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[FINALIZAR E LIMPAR] ❌ ERRO:', error.message);
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
