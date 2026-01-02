import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
    // Recebe exatamente o que a SQL finalizar_onboarding vai cuspir
    const { whatsapp, template_name } = await req.json();
    if (!whatsapp || !template_name) {
      throw new Error("Faltando whatsapp ou nome do template.");
    }
    // Pega as credenciais
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    // Limpa o número (deixa só digitos)
    const whatsappDestino = whatsapp.replace(/\D/g, '');
    console.log(`[Template Sender] Enviando '${template_name}' para ${whatsappDestino}`);
    // Monta o Payload Específico de Template
    const payload = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsappDestino,
      type: "template",
      template: {
        name: template_name,
        language: {
          code: "pt_BR"
        },
        components: [] // Sem variáveis, como combinamos
      }
    };
    // Dispara para a Meta
    const response = await fetch(`https://graph.facebook.com/v18.0/${metaPhoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${metaToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    const data = await response.json();
    if (!response.ok) {
      console.error('[Erro Meta]', data);
      throw new Error(data.error?.message || 'Erro desconhecido na Meta');
    }
    return new Response(JSON.stringify({
      success: true,
      id: data.messages[0].id
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
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
