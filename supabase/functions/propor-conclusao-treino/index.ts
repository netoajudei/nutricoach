/**
 * @name propor-conclusao-treino
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-07
 *
 * @description
 * 1. Recebe o tool_call da IA (orquestrador) com os dados do treino concluído.
 * 2. Busca o WhatsApp do aluno.
 * 3. Cria (UPSERT) um registro na tabela `botoes_ativos` com todos os argumentos.
 * 4. Define a `edge_function` de resposta como 'registrar-conclusao-treino'.
 * 5. Formata uma mensagem de confirmação para o usuário.
 * 6. Envia o botão de confirmação (Sim/Não) para o aluno via WAME.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
// ========================================
// FUNÇÃO PRINCIPAL
// ========================================
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  try {
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Receber payload do Orquestrador
    const body = await req.json();
    const { aluno_id, conversation_id, tool_call_id, argumentos } = body;
    console.log(`[propor-conclusao-treino] 🚀 Iniciando para aluno: ${aluno_id}`);
    console.log(`[propor-conclusao-treino] 🤖 Tool Call ID: ${tool_call_id}`);
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error('Payload incompleto. Faltando aluno_id, conversation_id, tool_call_id ou argumentos.');
    }
    // 2. Argumentos já vêm como Objeto JSON
    const args = argumentos;
    const { nome_treino, duracao, observacoes } = args;
    if (!nome_treino || duracao === undefined || observacoes === undefined) {
      throw new Error('Argumentos da IA incompletos. Faltando "nome_treino", "duracao" ou "observacoes".');
    }
    // 3. Buscar dados do aluno (WhatsApp)
    console.log(`[propor-conclusao-treino] 🔍 Buscando WhatsApp do aluno...`);
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError) throw alunoError;
    if (!alunoData) throw new Error(`Aluno ${aluno_id} não encontrado.`);
    const whatsappNumber = alunoData.whatsapp;
    console.log(`[propor-conclusao-treino] ✅ WhatsApp: ${whatsappNumber}`);
    // 4. Criar (UPSERT) o registro em `botoes_ativos`
    console.log(`[propor-conclusao-treino] 💾 Criando registro em botoes_ativos...`);
    const { data: botaoData, error: botaoError } = await supabase.from('botoes_ativos').upsert({
      aluno_id: aluno_id,
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      tipo_acao: 'conclusao_treino',
      argumentos: args,
      edge_function: 'registrar-conclusao-treino' // A função que será chamada na confirmação
    }, {
      onConflict: 'aluno_id'
    }).select('id').single();
    if (botaoError) throw botaoError;
    const botao_id = botaoData.id;
    console.log(`[propor-conclusao-treino] ✅ Registro de botão criado/atualizado: ${botao_id}`);
    // 5. Preparar payloads de botão (padrão centralizado)
    const payloadSim = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: true
    });
    const payloadNao = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: false
    });
    // 6. Buscar API Key da WAME
    console.log(`[propor-conclusao-treino] 🔑 Buscando API Key...`);
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError) throw configError;
    const api_key = configData.valor;
    // 7. Construir a mensagem
    const mensagemTexto = `🏋️ Confirmar Conclusão do Treino\n
• Treino: *${nome_treino}*
• Duração: *${duracao} minutos*
• Observações: *"${observacoes}"*

Confirmar este registro?`;
    const requestBody = {
      to: whatsappNumber,
      header: {
        title: '🏋️ Registro de Treino'
      },
      text: mensagemTexto,
      footer: 'Escolha uma opção:',
      buttons: [
        {
          type: 'quick_reply',
          id: payloadSim,
          text: 'Sim, registrar!'
        },
        {
          type: 'quick_reply',
          id: payloadNao,
          text: 'Não, cancelar'
        }
      ]
    };
    // 8. Enviar o botão para o WAME
    console.log(`[propor-conclusao-treino] 📤 Enviando botão para WAME...`);
    const wameResponse = await fetch(`https://us.api-wa.me/${api_key}/message/button_reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(requestBody)
    });
    if (!wameResponse.ok) {
      const errorBody = await wameResponse.text();
      throw new Error(`Erro ao enviar mensagem WAME: ${wameResponse.status} - ${errorBody}`);
    }
    console.log(`[propor-conclusao-treino] ✅ Proposta de conclusão de treino enviada com sucesso.`);
    // 9. Retornar OK para o Orquestrador
    return new Response(JSON.stringify({
      success: true,
      message: "Proposta de conclusão de treino enviada ao usuário."
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error(`[propor-conclusao-treino] ❌ ERRO:`, error.message);
    console.error(`[propor-conclusao-treino] Stack:`, error.stack);
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
