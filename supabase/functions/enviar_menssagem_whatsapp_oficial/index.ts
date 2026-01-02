/**
 * @name enviar_menssagem_whatsapp_oficial
 * @description
 * Versão Paralela: Envio de mensagens de TEXTO via WhatsApp Cloud API (Meta Oficial).
 * Utiliza Secrets para autenticação e mantém a compatibilidade com o Orquestrador.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  // Tratamento de CORS
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
    // 1. Validar Variáveis de Ambiente (Secrets)
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    if (!metaToken || !metaPhoneId) {
      throw new Error("Configuração da Meta incompleta. Verifique os Secrets: META_ACCESS_TOKEN e META_PHONE_ID.");
    }
    // 2. Buscar telefone do aluno no Supabase
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !aluno || !aluno.whatsapp) {
      throw new Error(`Aluno não encontrado ou sem telefone: ${aluno_id}`);
    }
    // 3. Sanitização do Telefone (Crítico para API Oficial)
    // Remove tudo que não for número (espaços, +, -, parênteses)
    // A API Oficial espera: 554899999999 (Código País + DDD + Número)
    const whatsappDestino = aluno.whatsapp.replace(/\D/g, '');
    // Opcional: Validação básica de DDI (se o seu público for só BR, garante o 55)
    // if (!whatsappDestino.startsWith('55')) { ... }
    console.log(`[Sender Oficial] 📤 Preparando envio para: ${whatsappDestino}`);
    // 4. Montar Payload da Meta
    const apiUrl = `https://graph.facebook.com/v18.0/${metaPhoneId}/messages`;
    const payload = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsappDestino,
      type: "text",
      text: {
        body: mensagem
      }
    };
    // 5. Enviar para a Meta
    const response = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${metaToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    const responseBody = await response.json();
    if (!response.ok) {
      console.error('[Sender Oficial] ❌ Erro Meta:', JSON.stringify(responseBody));
      throw new Error(`Erro API Meta: ${responseBody.error?.message || 'Erro desconhecido'}`);
    }
    // Sucesso!
    console.log(`[Sender Oficial] ✅ Enviado! Message ID: ${responseBody.messages?.[0]?.id}`);
    return new Response(JSON.stringify({
      success: true,
      provider: 'META_OFFICIAL',
      meta_id: responseBody.messages?.[0]?.id
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('🔥 Erro em enviar_menssagem_whatsapp_oficial:', error.message);
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
