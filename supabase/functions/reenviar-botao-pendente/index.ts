/**
 * @name reenviar-botao-pendente
 * @version 5.0.0 (Payload JSON Compatível + AI Context)
 * @description
 * 1. Gera texto amigável com IA.
 * 2. Gera os botões com IDs em formato JSON idênticos aos originais.
 * 3. Garante que o n8n processe o clique sem precisar de alteração de lógica.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const META_TOKEN = Deno.env.get("META_ACCESS_TOKEN");
const META_PHONE_ID = Deno.env.get("META_PHONE_ID");
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
serve(async (req)=>{
  if (req.method === 'OPTIONS') return new Response('ok', {
    headers: corsHeaders
  });
  try {
    const { botao_id, whatsapp } = await req.json();
    if (!botao_id || !whatsapp) throw new Error('Parâmetros obrigatórios faltando.');
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    // 1. BUSCAR DADOS DO BOTÃO
    const { data: botao, error } = await supabase.from('botoes_ativos').select('*').eq('id', botao_id).maybeSingle();
    if (error || !botao) {
      return new Response(JSON.stringify({
        success: false,
        message: "Botão não encontrado."
      }), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        },
        status: 200
      });
    }
    console.log(`[REENVIAR] 🔄 Reconstruindo botão ID: ${botao_id}`);
    // 2. GERAR TEXTO CONTEXTUAL (IA)
    let textoCorpo = "";
    try {
      const promptSistema = `
        Você é um assistente pessoal (NutriCoach). O usuário tentou mudar de assunto, mas tem uma pendência.
        Escreva uma mensagem CURTA (max 140 chars) e amigável pedindo para ele confirmar ou cancelar a ação abaixo.
        Ação: ${botao.tipo_acao}
        Dados: ${JSON.stringify(botao.argumentos)}
      `;
      const aiResponse = await fetch('https://api.openai.com/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          model: "gpt-4o-mini",
          messages: [
            {
              role: "system",
              content: promptSistema
            }
          ],
          temperature: 0.7,
          max_tokens: 100
        })
      });
      const aiData = await aiResponse.json();
      textoCorpo = aiData.choices?.[0]?.message?.content || `⚠️ Pendência: ${botao.tipo_acao}. Por favor confirme.`;
    } catch (e) {
      textoCorpo = `⚠️ *Ação Pendente*\n\nVocê possui um registro pendente (${botao.tipo_acao}). Confirme ou cancele para continuar.`;
    }
    // 3. MONTAR OS PAYLOADS JSON (EXATAMENTE COMO O ORIGINAL)
    // Isso garante que o n8n consiga ler o botao_id dentro do JSON
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
    // 4. ENVIAR PARA META
    const payloadMeta = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsapp,
      type: "interactive",
      interactive: {
        type: "button",
        body: {
          text: textoCorpo
        },
        action: {
          buttons: [
            {
              type: "reply",
              reply: {
                id: payloadSim,
                title: "✅ Confirmar"
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
    console.log(`[REENVIAR] 📡 Enviando Payload JSON...`);
    const metaResponse = await fetch(`https://graph.facebook.com/v21.0/${META_PHONE_ID}/messages`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${META_TOKEN}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payloadMeta)
    });
    if (!metaResponse.ok) {
      const errTxt = await metaResponse.text();
      throw new Error(`Meta API Error: ${errTxt}`);
    }
    return new Response(JSON.stringify({
      success: true
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (e) {
    return new Response(JSON.stringify({
      error: e.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
