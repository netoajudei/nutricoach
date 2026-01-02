/**
 * @name propor-registro-refeicao-meta
 * @description
 * Cópia fiel da lógica de 'propor-registro-refeicao', adaptada APENAS para o envio via Meta API Oficial.
 * Grava conversation_id e tool_call_id obrigatórios na tabela botoes_ativos.
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
    // 1. Receber dados (EXATAMENTE como o Orquestrador envia)
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    // Validação rigorosa dos campos obrigatórios do banco
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error("Parâmetros obrigatórios ausentes: aluno_id, conversation_id, tool_call_id, argumentos.");
    }
    // 2. Validar Secrets da Meta
    const metaToken = Deno.env.get('META_ACCESS_TOKEN');
    const metaPhoneId = Deno.env.get('META_PHONE_ID');
    if (!metaToken || !metaPhoneId) {
      throw new Error("Secrets META_ACCESS_TOKEN e META_PHONE_ID não configurados.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL') ?? '', Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '');
    // 3. Buscar WhatsApp do Aluno
    const { data: aluno, error: erroAluno } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (erroAluno || !aluno || !aluno.whatsapp) {
      throw new Error("Aluno não encontrado ou sem WhatsApp cadastrado.");
    }
    // Sanitização para API Oficial (apenas números)
    const whatsappDestino = aluno.whatsapp.replace(/\D/g, '');
    // 4. Lógica de Negócio: Gravar o estado do botão (CÓPIA DA ORIGINAL)
    // Usamos UPSERT no aluno_id para garantir unicidade, gravando TODOS os campos obrigatórios.
    const { data: botaoInserido, error: erroBotao } = await supabase.from('botoes_ativos').upsert({
      aluno_id: aluno_id,
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      tipo_acao: 'registro_refeicao',
      edge_function: 'finalizar-registro-refeicao',
      argumentos: argumentos
    }, {
      onConflict: 'aluno_id'
    }) // Se já existir botão para este aluno, atualiza.
    .select('id').single();
    if (erroBotao) {
      console.error("Erro ao gravar botoes_ativos:", erroBotao);
      throw new Error(`Erro de banco de dados: ${erroBotao.message}`);
    }
    const idBotaoBanco = botaoInserido.id;
    // 5. Preparar Payloads (Usando o ID gerado)
    const payloadSim = JSON.stringify({
      action: 'resposta_botao',
      botao_id: idBotaoBanco,
      confirmado: true
    });
    const payloadNao = JSON.stringify({
      action: 'resposta_botao',
      botao_id: idBotaoBanco,
      confirmado: false
    });
    // 6. Montar JSON da Meta (Interactive Message) - AQUI ESTÁ A ADAPTAÇÃO
    const { refeicao, tipo, calorias } = argumentos;
    const mensagemTexto = `🍽️ *Confirmação de Refeição*\n\n` + `Você registrou: *${tipo}*\n` + `_${refeicao}_\n\n` + `🔥 Calorias estimadas: *${calorias} kcal*\n\n` + `Podemos confirmar?`;
    const bodyMeta = {
      messaging_product: "whatsapp",
      recipient_type: "individual",
      to: whatsappDestino,
      type: "interactive",
      interactive: {
        type: "button",
        body: {
          text: mensagemTexto
        },
        footer: {
          text: "NutriCoach AI"
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
    // 7. Enviar para a Meta
    console.log(`[Propor Refeição Meta] 📤 Enviando para ${whatsappDestino}...`);
    const response = await fetch(`https://graph.facebook.com/v18.0/${metaPhoneId}/messages`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${metaToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(bodyMeta)
    });
    const responseData = await response.json();
    if (!response.ok) {
      console.error('[Propor Refeição Meta] ❌ Erro Meta:', JSON.stringify(responseData));
      throw new Error(`Erro API Meta: ${responseData.error?.message || 'Erro desconhecido'}`);
    }
    console.log(`[Propor Refeição Meta] ✅ Sucesso! Message ID: ${responseData.messages?.[0]?.id}`);
    // 8. Retorno Padronizado para o Orquestrador
    return new Response(JSON.stringify({
      success: true,
      provider: 'META_OFFICIAL',
      message: "Proposta enviada com sucesso"
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error(`[Propor Refeição Meta] ❌ Erro:`, error.message);
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
