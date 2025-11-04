/**
 * @name cancelar-registro
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 01:20:00 -03:00
 * 
 * @description
 * Edge Function GENÉRICA para cancelar qualquer tipo de registro/ação.
 * Finaliza o function calling na OpenAI informando o cancelamento e
 * obtém uma resposta contextual da IA para enviar ao usuário.
 * 
 * @workflow
 * 1. Recebe aluno_id, whatsapp, conversation_id, tool_call_id
 * 2. NÃO executa nenhuma RPC (não salva nada no banco)
 * 3. Finaliza function calling na OpenAI com mensagem de cancelamento
 * 4. Obtém resposta contextual da IA
 * 5. Envia resposta ao usuário via WhatsApp
 * 6. Limpa bloqueio (aguardando_confirmacao = NULL)
 * 7. Retorna sucesso
 * 
 * @usage
 * Esta função é genérica e serve para:
 * - cancelar_registro_refeicao
 * - cancelar_update_carga
 * - qualquer outra ação que precise ser cancelada
 * 
 * @param {string} aluno_id - ID do aluno
 * @param {string} whatsapp - Número WhatsApp do aluno
 * @param {string} conversation_id - ID da conversation OpenAI
 * @param {string} tool_call_id - ID do tool call a ser finalizado
 * 
 * @returns {object} { success, message }
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
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') || 'gpt-5-mini';
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    console.log('[CANCELAR REGISTRO] 🚀 Iniciando');
    const { aluno_id, whatsapp, conversation_id, tool_call_id } = await req.json();
    if (!aluno_id || !whatsapp || !conversation_id || !tool_call_id) {
      throw new Error('Parâmetros obrigatórios faltando');
    }
    console.log('[CANCELAR REGISTRO] 📋 Dados recebidos:');
    console.log('[CANCELAR REGISTRO] - Aluno ID:', aluno_id);
    console.log('[CANCELAR REGISTRO] - Conversation ID:', conversation_id);
    console.log('[CANCELAR REGISTRO] - Tool Call ID:', tool_call_id);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. FINALIZAR FUNCTION CALLING NA OPENAI
    // ============================================
    console.log('[CANCELAR REGISTRO] 🔄 Finalizando function calling...');
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
            status: "Cancelado",
            message: "Usuário cancelou a operação. Nenhuma alteração foi feita."
          })
        }
      ]
    };
    console.log('[CANCELAR REGISTRO] 📤 Enviando para OpenAI...');
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
    console.log('[CANCELAR REGISTRO] ✅ Function calling finalizado');
    console.log('[CANCELAR REGISTRO] 📊 Response ID:', openaiData.id);
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
      console.warn('[CANCELAR REGISTRO] ⚠️ Resposta vazia da IA, usando fallback');
      respostaIA = 'Ok! 👍 Operação cancelada. Se precisar de algo, é só me avisar!';
    }
    console.log('[CANCELAR REGISTRO] 💬 Resposta:', respostaIA.substring(0, 100));
    // ============================================
    // 3. ENVIAR RESPOSTA AO USUÁRIO
    // ============================================
    console.log('[CANCELAR REGISTRO] 📱 Enviando mensagem ao usuário...');
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
    console.log('[CANCELAR REGISTRO] ✅ Mensagem enviada');
    // ============================================
    // 4. LIMPAR BLOQUEIO
    // ============================================
    console.log('[CANCELAR REGISTRO] 🔓 Limpando bloqueio...');
    await supabase.from('alunos').update({
      aguardando_confirmacao: null
    }).eq('id', aluno_id);
    console.log('[CANCELAR REGISTRO] ✅ Bloqueio removido');
    // ============================================
    // 5. RETORNAR SUCESSO
    // ============================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Registro cancelado e bloqueio removido',
      resposta_enviada: respostaIA
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[CANCELAR REGISTRO] ❌ ERRO:', error.message);
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
