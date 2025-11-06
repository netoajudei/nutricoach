/**
 * @name propor-atualizacao-carga
 * @version 4.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-05 01:15:00 -03:00
 * 
 * @description
 * Edge Function PADRONIZADA para propor atualização de carga.
 * Agora registra botão na tabela botoes_ativos.
 * 
 * @changelog
 * - v4.0.0: Integração com tabela botoes_ativos (UPSERT)
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
    console.log('[PROPOR CARGA v4.0] 🚀 Iniciando');
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    // ========================================
    // VALIDAÇÕES
    // ========================================
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error('Parâmetros obrigatórios faltando: aluno_id, conversation_id, tool_call_id, argumentos');
    }
    const { id_exercicio, variacao_de_carga, nome_exercicio } = argumentos;
    if (!id_exercicio || variacao_de_carga === undefined) {
      throw new Error('Argumentos incompletos: id_exercicio e variacao_de_carga são obrigatórios');
    }
    console.log('[PROPOR CARGA v4.0] 📋 Dados recebidos:');
    console.log('[PROPOR CARGA v4.0] - Aluno ID:', aluno_id);
    console.log('[PROPOR CARGA v4.0] - Conversation ID:', conversation_id);
    console.log('[PROPOR CARGA v4.0] - Tool Call ID:', tool_call_id);
    console.log('[PROPOR CARGA v4.0] - Exercício ID:', id_exercicio);
    console.log('[PROPOR CARGA v4.0] - Variação:', variacao_de_carga, 'kg');
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR EXERCÍCIO E WHATSAPP
    // ========================================
    console.log('[PROPOR CARGA v4.0] 🔍 Buscando exercício...');
    const { data: exercicio, error: exercicioError } = await supabase.from('workout_exercises').select('nome_exercicio, carga_kg').eq('id', id_exercicio).single();
    if (exercicioError || !exercicio) {
      throw new Error('Exercício não encontrado');
    }
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !alunoData) {
      throw new Error('Aluno não encontrado');
    }
    const whatsapp = alunoData.whatsapp;
    const carga_atual = exercicio.carga_kg || 0;
    const nova_carga = carga_atual + variacao_de_carga;
    console.log('[PROPOR CARGA v4.0] ✅ Exercício:', exercicio.nome_exercicio);
    console.log('[PROPOR CARGA v4.0] 📊 Carga atual:', carga_atual, 'kg');
    console.log('[PROPOR CARGA v4.0] 📊 Nova carga:', nova_carga, 'kg');
    console.log('[PROPOR CARGA v4.0] 📱 WhatsApp:', whatsapp);
    // ========================================
    // CONSTRUIR MENSAGEM
    // ========================================
    const mensagem_texto = variacao_de_carga > 0 ? `💪 Notei que você progrediu no exercício *${exercicio.nome_exercicio}*!

Deseja atualizar a carga de ${carga_atual}kg para **${nova_carga}kg** no seu plano para os próximos treinos?` : `🔧 Notei um ajuste no exercício *${exercicio.nome_exercicio}*.

Deseja reduzir a carga de ${carga_atual}kg para **${nova_carga}kg** no seu plano?`;
    // ========================================
    // PREPARAR PAYLOADS DOS BOTÕES
    // ========================================
    const botao_id = crypto.randomUUID();
    const payload_sim = {
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: true
    };
    const payload_nao = {
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: false
    };
    console.log('[PROPOR CARGA v4.0] ✅ Botão ID:', botao_id);
    // ========================================
    // REGISTRAR BOTÃO NO BANCO (UPSERT)
    // ========================================
    console.log('[PROPOR CARGA v4.0] 💾 Registrando botão ativo...');
    const { error: botaoError } = await supabase.from('botoes_ativos').upsert({
      id: botao_id,
      aluno_id: aluno_id,
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      tipo_acao: 'update_carga',
      argumentos: {
        exercicio_id: id_exercicio,
        nova_carga: nova_carga,
        carga_atual: carga_atual,
        nome_exercicio: exercicio.nome_exercicio,
        whatsapp: whatsapp
      },
      edge_function: 'atualizar-carga-exercicio'
    }, {
      onConflict: 'aluno_id'
    });
    if (botaoError) {
      console.error('[PROPOR CARGA v4.0] ❌ Erro ao registrar botão:', botaoError);
      throw new Error(`Erro ao registrar botão: ${botaoError.message}`);
    }
    console.log('[PROPOR CARGA v4.0] ✅ Botão registrado');
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
    console.log('[PROPOR CARGA v4.0] 📤 Enviando botão...');
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
    console.log('[PROPOR CARGA v4.0] ✅ Botão enviado com sucesso');
    // ========================================
    // RETORNAR SUCESSO
    // ========================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta de atualização enviada ao aluno',
      detalhes: {
        botao_id: botao_id,
        exercicio_id: id_exercicio,
        nome_exercicio: exercicio.nome_exercicio,
        carga_atual: carga_atual,
        nova_carga: nova_carga,
        variacao: variacao_de_carga,
        aluno_id: aluno_id,
        whatsapp: whatsapp
      }
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROPOR CARGA v4.0] ❌ ERRO:', error.message);
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
