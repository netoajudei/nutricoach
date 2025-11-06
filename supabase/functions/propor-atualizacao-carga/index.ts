/**
 * @name propor-atualizacao-carga
 * @version 2.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 20:50:00 -03:00
 * 
 * @description
 * Edge Function que propõe atualização de carga de exercício.
 * Envia botão de confirmação ao usuário e salva dados em aguardando_confirmacao.
 * 
 * @workflow
 * 1. Recebe exercicio_id, variacao_kg, conversation_id, tool_call_id
 * 2. Busca dados do exercício e aluno
 * 3. Calcula nova carga
 * 4. Monta payloads dos botões (SIM e NÃO)
 * 5. Salva em aguardando_confirmacao com conversation_id e tool_call_id
 * 6. Envia botão via WhatsApp
 * 7. Retorna sucesso
 * 
 * @param {string} exercicio_id - ID do exercício
 * @param {number} variacao_kg - Variação em kg (positiva ou negativa)
 * @param {string} conversation_id - ID da conversation OpenAI
 * @param {string} tool_call_id - ID do tool call OpenAI
 * 
 * @returns {object} { success, message, detalhes }
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
    console.log('[PROPOR CARGA] 🚀 Iniciando');
    const { exercicio_id, variacao_kg, conversation_id, tool_call_id } = await req.json();
    // ========================================
    // VALIDAÇÕES
    // ========================================
    if (!exercicio_id || variacao_kg === undefined || !conversation_id || !tool_call_id) {
      throw new Error('Parâmetros obrigatórios faltando');
    }
    console.log('[PROPOR CARGA] 📋 Dados recebidos:');
    console.log('[PROPOR CARGA] - Exercício ID:', exercicio_id);
    console.log('[PROPOR CARGA] - Variação:', variacao_kg, 'kg');
    console.log('[PROPOR CARGA] - Conversation ID:', conversation_id);
    console.log('[PROPOR CARGA] - Tool Call ID:', tool_call_id);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR EXERCÍCIO E ALUNO
    // ========================================
    console.log('[PROPOR CARGA] 🔍 Buscando exercício...');
    const { data: exercicio, error: exercicioError } = await supabase.from('workout_exercises').select(`
        id,
        nome_exercicio,
        carga_kg,
        workout_id,
        program_workouts!inner (
          program_id,
          workout_programs!inner (
            aluno_id,
            alunos!inner (
              whatsapp
            )
          )
        )
      `).eq('id', exercicio_id).single();
    if (exercicioError || !exercicio) {
      console.error('[PROPOR CARGA] ❌ Exercício não encontrado:', exercicioError?.message);
      throw new Error('Exercício não encontrado');
    }
    const aluno_id = exercicio.program_workouts.workout_programs.aluno_id;
    const whatsapp = exercicio.program_workouts.workout_programs.alunos.whatsapp;
    const carga_atual = exercicio.carga_kg || 0;
    const nova_carga = carga_atual + variacao_kg;
    console.log('[PROPOR CARGA] ✅ Exercício:', exercicio.nome_exercicio);
    console.log('[PROPOR CARGA] 📊 Carga atual:', carga_atual, 'kg');
    console.log('[PROPOR CARGA] 📊 Nova carga:', nova_carga, 'kg');
    console.log('[PROPOR CARGA] 👤 Aluno ID:', aluno_id);
    console.log('[PROPOR CARGA] 📱 WhatsApp:', whatsapp);
    // ========================================
    // CONSTRUIR MENSAGEM
    // ========================================
    const mensagem_texto = variacao_kg > 0 ? `💪 Notei que você progrediu no exercício *${exercicio.nome_exercicio}*!

Deseja atualizar a carga de ${carga_atual}kg para **${nova_carga}kg** no seu plano para os próximos treinos?` : `🔧 Notei um ajuste no exercício *${exercicio.nome_exercicio}*.

Deseja reduzir a carga de ${carga_atual}kg para **${nova_carga}kg** no seu plano?`;
    // ========================================
    // PREPARAR PAYLOADS DOS BOTÕES
    // ========================================
    const payload_sim = {
      action: 'confirmar_update_carga',
      exercicio_id: exercicio_id,
      nova_carga: nova_carga,
      aluno_id: aluno_id
    };
    const payload_nao = {
      action: 'cancelar_update_carga',
      exercicio_id: exercicio_id,
      aluno_id: aluno_id
    };
    console.log('[PROPOR CARGA] ✅ Payloads criados');
    // ========================================
    // SALVAR EM AGUARDANDO_CONFIRMACAO
    // ========================================
    console.log('[PROPOR CARGA] 💾 Salvando em aguardando_confirmacao...');
    const aguardando_confirmacao_data = {
      aguardando: true,
      tipo: 'update_carga',
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      exercicio_id: exercicio_id,
      carga_atual: carga_atual,
      nova_carga: nova_carga,
      button_payload_sim: payload_sim,
      button_payload_nao: payload_nao,
      timestamp: new Date().toISOString()
    };
    const { error: updateError } = await supabase.from('alunos').update({
      aguardando_confirmacao: aguardando_confirmacao_data
    }).eq('id', aluno_id);
    if (updateError) {
      console.error('[PROPOR CARGA] ❌ Erro ao salvar aguardando_confirmacao:', updateError);
      throw new Error(`Erro ao salvar bloqueio: ${updateError.message}`);
    }
    console.log('[PROPOR CARGA] ✅ Bloqueio salvo');
    // ========================================
    // BUSCAR API KEY
    // ========================================
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError || !configData) {
      throw new Error('WAME_API_KEY não encontrada');
    }
    const api_key = configData.valor;
    // ========================================
    // ENVIAR BOTÃO VIA WHATSAPP
    // ========================================
    console.log('[PROPOR CARGA] 📤 Enviando botão...');
    const api_url = `https://us.api-wa.me/${api_key}/message/button_reply`;
    const request_body = {
      to: whatsapp,
      header: {
        title: '💪 Confirmação de Progresso'
      },
      text: mensagem_texto,
      footer: 'Escolha uma opção:',
      buttons: [
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_sim),
          text: '✅ Sim, atualizar!'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_nao),
          text: '❌ Não, manter'
        }
      ]
    };
    const wameResponse = await fetch(api_url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(request_body)
    });
    if (!wameResponse.ok) {
      const responseBody = await wameResponse.text();
      throw new Error(`[WAME] Erro ${wameResponse.status}: ${responseBody}`);
    }
    console.log('[PROPOR CARGA] ✅ Botão enviado com sucesso');
    // ========================================
    // RETORNAR SUCESSO
    // ========================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta de atualização enviada ao aluno',
      detalhes: {
        exercicio_id: exercicio_id,
        nome_exercicio: exercicio.nome_exercicio,
        carga_atual: carga_atual,
        nova_carga: nova_carga,
        variacao: variacao_kg,
        aluno_id: aluno_id,
        whatsapp: whatsapp,
        conversation_id: conversation_id,
        tool_call_id: tool_call_id
      }
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROPOR CARGA] ❌ ERRO:', error.message);
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
