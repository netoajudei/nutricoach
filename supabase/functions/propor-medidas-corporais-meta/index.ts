/**
 * @name propor-medidas-corporais-meta
 * @description CLONE OFICIAL: Envia botão de confirmação de medidas via Meta API.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
// Helper para formatar o texto (Mantido da original)
function construirMensagemMedidas(args) {
  let listaMedidas = `• Peso: ${args.peso} kg\n`;
  const mapaMedidas = {
    cintura: "Cintura",
    quadril: "Quadril",
    peito: "Peito",
    percentual_gordura: "Gordura (%)",
    braco_dir: "Braço Dir.",
    braco_esq: "Braço Esq.",
    coxa_dir: "Coxa Dir.",
    coxa_esq: "Coxa Esq.",
    panturrilha_dir: "Panturrilha Dir.",
    panturrilha_esq: "Panturrilha Esq."
  };
  for(const key in mapaMedidas){
    if (args[key] && args[key] > 0) {
      const nome = mapaMedidas[key];
      const unidade = key === 'percentual_gordura' ? '%' : 'cm';
      listaMedidas += `• ${nome}: ${args[key]} ${unidade}\n`;
    }
  }
  return `⚖️ *Confirmar Medidas*\n\nVocê me informou:\n\n${listaMedidas}\nConfirmar este registro?`;
}
serve(async (req)=>{
  if (req.method === 'OPTIONS') return new Response('ok', {
    headers: corsHeaders
  });
  try {
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) throw new Error('Payload incompleto.');
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    // Buscar WhatsApp
    const { data: aluno } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (!aluno?.whatsapp) throw new Error('Aluno sem WhatsApp.');
    const whatsappDestino = aluno.whatsapp.replace(/\D/g, '');
    // Gravar Botão (Lógica Original)
    const { data: botao, error: botaoError } = await supabase.from('botoes_ativos').upsert({
      aluno_id,
      conversation_id,
      tool_call_id,
      tipo_acao: 'medidas_corporais',
      argumentos,
      edge_function: 'atualizar_medidas_corporais'
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
    // Enviar Meta (Interactive)
    const bodyMeta = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsappDestino,
      type: "interactive",
      interactive: {
        type: "button",
        body: {
          text: construirMensagemMedidas(argumentos)
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
                title: "❌ Não, alterar"
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
