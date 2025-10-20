/**
 * @name enviar_menssagem_whatsapp
 * @version 2.2.2 (Debug Final)
 * @description
 * Versão de depuração final com logging aprimorado para capturar e exibir
 * o corpo completo da resposta da API externa (WAME ou WAAPI).
 *
 * @changelog
 * - v2.2.2: Adicionado um `console.log` para o corpo da resposta (`responseData`)
 * mesmo em caso de sucesso, para permitir a inspeção do que a API
 * externa está realmente retornando.
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
    const { aluno_id, mensagem } = await req.json();
    if (!aluno_id || !mensagem) {
      throw new Error("Dados incompletos: `aluno_id` e `mensagem` são obrigatórios.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !aluno) {
      throw new Error(`Aluno não encontrado: ${aluno_id}`);
    }
    let responseData;
    let providerUsed;
    const activeProvider = Deno.env.get('ACTIVE_WHATSAPP_PROVIDER');
    console.log(`[Sender] Provedor ativo: ${activeProvider || 'WAAPI (Padrão)'}`);
    if (activeProvider === 'WAME') {
      providerUsed = 'WAME';
      const apiKey = Deno.env.get('WAME_API_KEY');
      if (!apiKey) throw new Error("Variável de ambiente WAME_API_KEY não configurada.");
      const apiUrl = `https://us.api-wa.me/${apiKey}/message/text`;
      const payload = {
        to: aluno.whatsapp,
        text: mensagem
      };
      console.log(`[Sender] Enviando para WAME. URL: ${apiUrl}`);
      console.log(`[Sender] Payload para WAME: ${JSON.stringify(payload)}`);
      const response = await fetch(apiUrl, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
      });
      // Captura o corpo da resposta independentemente do status
      const responseBodyText = await response.text();
      if (!response.ok) {
        throw new Error(`[WAME] API retornou erro ${response.status}: ${responseBodyText}`);
      }
      responseData = JSON.parse(responseBodyText);
    } else {
      providerUsed = 'WAAPI';
      const waapiToken = Deno.env.get('WAAPI_TOKEN');
      const waapiInstanceId = Deno.env.get('WAAPI_INSTANCE_ID');
      if (!waapiToken || !waapiInstanceId) throw new Error("Variáveis de ambiente WAAPI não configuradas.");
      const chatId = `${aluno.whatsapp}@c.us`;
      const apiUrl = `https://waapi.app/api/v1/instances/${waapiInstanceId}/client/action/send-message`;
      const payload = {
        chatId: chatId,
        message: mensagem
      };
      console.log(`[Sender] Enviando para WAAPI. URL: ${apiUrl}`);
      console.log(`[Sender] Payload para WAAPI: ${JSON.stringify(payload)}`);
      const response = await fetch(apiUrl, {
        method: 'POST',
        headers: {
          'Accept': 'application/json',
          'Authorization': `Bearer ${waapiToken}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
      });
      const responseBodyText = await response.text();
      if (!response.ok) {
        throw new Error(`[WAAPI] API retornou erro ${response.status}: ${responseBodyText}`);
      }
      responseData = JSON.parse(responseBodyText);
    }
    // <<-- LOG ADICIONAL AQUI -->>
    // Imprime a resposta completa da API externa para análise
    console.log(`[Sender] Resposta completa recebida da API [${providerUsed}]:`, JSON.stringify(responseData, null, 2));
    console.log(`[Sender] Mensagem enviada com sucesso via ${providerUsed}.`);
    return new Response(JSON.stringify({
      success: true,
      provider: providerUsed,
      response: responseData
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('🔥 Erro em enviar_menssagem_whatsapp:', error.message);
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
