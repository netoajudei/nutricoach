/**
 * @name propor-atualizacao-carga-meta
 * @description CLONE OFICIAL: Envia botão de atualização de carga via Meta API.
 * FIX: Mapeia corretamente 'id_exercicio' para 'exercicio_id' nos argumentos.
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
    // A IA manda 'id_exercicio', mas nosso sistema usa 'exercicio_id' internamente
    const { id_exercicio, variacao_de_carga } = argumentos;
    if (!aluno_id || !conversation_id || !tool_call_id || !id_exercicio) throw new Error('Payload incompleto.');
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    // Buscar Exercício e Aluno
    const { data: exercicio } = await supabase.from('workout_exercises').select('nome_exercicio, carga_kg').eq('id', id_exercicio).single();
    const { data: aluno } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (!exercicio || !aluno?.whatsapp) throw new Error('Exercício ou Aluno não encontrado.');
    const whatsappDestino = aluno.whatsapp.replace(/\D/g, '');
    const carga_atual = exercicio.carga_kg || 0;
    const nova_carga = carga_atual + variacao_de_carga;
    const emoji = variacao_de_carga > 0 ? '💪' : '🔧';
    const acao = variacao_de_carga > 0 ? 'progrediu' : 'ajuste';
    // Gravar Botão (COM A CORREÇÃO DE MAPEAMENTO)
    const { data: botao, error: botaoError } = await supabase.from('botoes_ativos').upsert({
      aluno_id,
      conversation_id,
      tool_call_id,
      tipo_acao: 'update_carga',
      argumentos: {
        // AQUI ESTÁ A CORREÇÃO CRUCIAL:
        exercicio_id: id_exercicio,
        nova_carga: nova_carga,
        carga_atual: carga_atual,
        nome_exercicio: exercicio.nome_exercicio,
        whatsapp: whatsappDestino,
        ...argumentos
      },
      edge_function: 'atualizar-carga-exercicio'
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
    const texto = `${emoji} Notei ${acao} no exercício *${exercicio.nome_exercicio}*!\n\nDeseja atualizar a carga de ${carga_atual}kg para *${nova_carga}kg*?`;
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
                title: "✅ Sim, atualizar"
              }
            },
            {
              type: "reply",
              reply: {
                id: payloadNao,
                title: "❌ Não, manter"
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
