/**
 * @name registrar-tokens
 * @version 1.0.0
 * @author NutriCoach AI Development
 * @date 2025-10-14
 *
 * @description
 * Esta Edge Function é um serviço de logging assíncrono. Sua única
 * responsabilidade é receber métricas de uso da API da OpenAI e inseri-las
 * na tabela `usage_metrics`. É projetada para ser rápida e leve,
 * executando em segundo plano sem impactar a performance da resposta ao usuário.
 *
 * @endpoint POST /functions/v1/registrar-tokens
 *
 * @param {object} body - O corpo da requisição com os dados de métricas.
 *
 * @returns {Response} Uma resposta de sucesso ou erro.
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
    const metricsPayload = await req.json();
    // Validação mínima para garantir que os dados essenciais estão presentes
    if (!metricsPayload.aluno_id || !metricsPayload.mensagem_id) {
      throw new Error("Payload de métricas inválido. `aluno_id` e `mensagem_id` são necessários.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // Insere os dados recebidos diretamente na tabela de métricas
    const { error } = await supabase.from('usage_metrics').insert({
      aluno_id: metricsPayload.aluno_id,
      mensagem_id: metricsPayload.mensagem_id,
      modelo_utilizado: metricsPayload.modelo_utilizado,
      input_tokens: metricsPayload.input_tokens,
      output_tokens: metricsPayload.output_tokens,
      cached_tokens: metricsPayload.cached_tokens,
      web_search_ativado: metricsPayload.web_search_ativado,
      api_response_body: metricsPayload.api_response_body
    });
    if (error) {
      throw new Error(`[Logger] Erro ao inserir métricas: ${error.message}`);
    }
    console.log(`[Logger] Métricas para a mensagem ${metricsPayload.mensagem_id} registradas com sucesso.`);
    return new Response(JSON.stringify({
      success: true
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error("🔥 Erro na função registrar-tokens:", error.message);
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
