/**
 * @name orquestrador-ia
 * @version 3.1.0
 * @description
 * Conversation ID é gerenciado pela OpenAI automaticamente via previous_response_id
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
  const body = await req.json().catch(()=>({}));
  const mensagem_id = body.mensagem_id;
  try {
    console.log('[Orquestrador v3.1] Usando previous_response_id');
    if (!mensagem_id) throw new Error("O 'mensagem_id' é obrigatório.");
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Busca mensagem
    const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').select('aluno_id, mensagem').eq('id', mensagem_id).single();
    if (msgError) throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    // 2. Busca último response_id do aluno
    const { data: promptData } = await supabase.from('dynamic_prompts').select('last_response_id, prompt_final').eq('aluno_id', aluno_id).single();
    const { last_response_id, prompt_final } = promptData || {};
    console.log(`[Orquestrador] Last response ID: ${last_response_id || 'Primeira mensagem'}`);
    // 3. Monta payload
    const payload = {
      model: Deno.env.get('OPENAI_MODEL') || "gpt-5-mini",
      input: perguntaUsuario,
      store: true
    };
    // Se é primeira mensagem, envia instructions
    if (!last_response_id && prompt_final) {
      payload.instructions = prompt_final;
      console.log('[Orquestrador] Primeira mensagem - enviando instructions');
    }
    // Se não é primeira, usa previous_response_id
    if (last_response_id) {
      payload.previous_response_id = last_response_id;
      console.log('[Orquestrador] Usando previous_response_id para continuidade');
    }
    // 4. Chama API
    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    if (!openaiResponse.ok) {
      const errorBody = await openaiResponse.text();
      throw new Error(`Erro na API da OpenAI: ${errorBody}`);
    }
    const responseData = await openaiResponse.json();
    // 5. Salva o response_id para próxima mensagem
    await supabase.from('dynamic_prompts').update({
      last_response_id: responseData.id
    }).eq('aluno_id', aluno_id);
    // 6. Extrai resposta
    let respostaIA = '';
    for (const item of responseData.output){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) throw new Error("Resposta vazia da IA.");
    // 7. Salva resposta
    await supabase.from('mensagens_temporarias').update({
      resposta: respostaIA
    }).eq('id', mensagem_id);
    // 8. Envia WhatsApp
    console.log(`[Orquestrador] Invocando 'enviar_menssagem_whatsapp'`);
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
    // 9. Logging
    supabase.functions.invoke('registrar-tokens', {
      body: {
        aluno_id: aluno_id,
        mensagem_id: mensagem_id,
        modelo_utilizado: responseData.model,
        input_tokens: responseData.usage?.input_tokens ?? 0,
        cached_tokens: responseData.usage?.input_tokens_details?.cached_tokens ?? 0,
        output_tokens: responseData.usage?.output_tokens ?? 0,
        response_id: responseData.id,
        api_response_body: responseData
      }
    }).catch(console.error);
    console.log('[Orquestrador] Concluído.');
    console.log(`[Métricas] Cached: ${responseData.usage?.input_tokens_details?.cached_tokens ?? 0}`);
    return new Response(JSON.stringify({
      success: true,
      response_id: responseData.id,
      cached_tokens: responseData.usage?.input_tokens_details?.cached_tokens ?? 0
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[Orquestrador] ERRO:', error.message);
    if (mensagem_id) {
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      await supabaseAdmin.from('mensagens_temporarias').update({
        resposta: `ERRO: ${error.message}`
      }).eq('id', mensagem_id);
    }
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
