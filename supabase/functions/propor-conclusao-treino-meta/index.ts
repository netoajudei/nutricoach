/**
 * @name propor-conclusao-treino-meta
 * @description CLONE OFICIAL: Envia botão de conclusão de treino via Meta API.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  if (req.method === 'OPTIONS') return new Response('ok', {
    headers: corsHeaders
  });
  try {
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    const { nome_treino, duracao, observacoes } = argumentos;
    if (!aluno_id || !conversation_id || !tool_call_id || !nome_treino) throw new Error('Payload incompleto.');
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    // Buscar Aluno
    const { data: aluno } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (!aluno?.whatsapp) throw new Error('Aluno sem WhatsApp.');
    const whatsappDestino = aluno.whatsapp.replace(/\D/g, '');
    // Gravar Botão
    const { data: botao, error: botaoError } = await supabase.from('botoes_ativos').upsert({
      aluno_id,
      conversation_id,
      tool_call_id,
      tipo_acao: 'conclusao_treino',
      argumentos,
      edge_function: 'registrar-conclusao-treino'
    }, {
      onConflict: 'aluno_id'
    }).select('id').single();
    if (botaoError) throw botaoError;
    // Payloads
    const payloadSim = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao.id,
      confirmado: true
    });
    const payloadNao = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao.id,
      confirmado: false
    });
    // Mensagem
    const texto = `🏋️ *Confirmar Conclusão do Treino*\n\n• Treino: *${nome_treino}*\n• Duração: *${duracao} min*\n• Obs: _"${observacoes || 'Nenhuma'}"_\n\nConfirmar este registro?`;
    // Enviar Meta
    const bodyMeta = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsappDestino,
      type: "interactive",
      interactive: {
        type: "button",
        body: {
          text: texto
        },
        action: {
          buttons: [
            {
              type: "reply",
              reply: {
                id: payloadSim,
                title: "✅ Sim, registrar"
              }
            },
            {
              type: "reply",
              reply: {
                id: payloadNao,
                title: "❌ Cancelar"
              }
            }
          ]
        }
      }
    };
    await fetch(`https://graph.facebook.com/v18.0/${metaPhoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${metaToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(bodyMeta)
    });
    return new Response(JSON.stringify({
      success: true,
      provider: 'META_OFFICIAL'
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
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
