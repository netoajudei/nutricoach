/**
 * @name propor-registro-refeicao
 * @version 3.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 22:30:00 -03:00
 * 
 * @description
 * Edge Function PADRONIZADA para propor registro de refeição.
 * Recebe formato unificado de parâmetros.
 * 
 * @param {string} aluno_id - ID do aluno
 * @param {string} conversation_id - ID da conversation OpenAI
 * @param {string} tool_call_id - ID do tool call OpenAI
 * @param {object} argumentos - Argumentos da tool call
 * @param {string} argumentos.refeicao - Descrição da refeição
 * @param {string} argumentos.tipo - Tipo da refeição
 * @param {number} argumentos.calorias - Calorias
 * @param {number} argumentos.proteinas - Proteínas em g
 * @param {number} argumentos.carboidratos - Carboidratos em g
 * @param {number} argumentos.gorduras - Gorduras em g
 * @param {number} argumentos.liquidos - Líquidos em litros
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
    console.log('[PROPOR REFEIÇÃO v3.0] 🚀 Iniciando');
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    // ========================================
    // VALIDAÇÕES
    // ========================================
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error('Parâmetros obrigatórios faltando: aluno_id, conversation_id, tool_call_id, argumentos');
    }
    const { refeicao, tipo, calorias, proteinas, carboidratos, gorduras, liquidos } = argumentos;
    if (!refeicao || !tipo || calorias === undefined) {
      throw new Error('Argumentos incompletos na refeição');
    }
    console.log('[PROPOR REFEIÇÃO v3.0] 📋 Dados recebidos:');
    console.log('[PROPOR REFEIÇÃO v3.0] - Aluno ID:', aluno_id);
    console.log('[PROPOR REFEIÇÃO v3.0] - Conversation ID:', conversation_id);
    console.log('[PROPOR REFEIÇÃO v3.0] - Tool Call ID:', tool_call_id);
    console.log('[PROPOR REFEIÇÃO v3.0] - Refeição:', refeicao.substring(0, 50));
    console.log('[PROPOR REFEIÇÃO v3.0] - Tipo:', tipo);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR WHATSAPP DO ALUNO
    // ========================================
    console.log('[PROPOR REFEIÇÃO v3.0] 🔍 Buscando whatsapp...');
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !alunoData) {
      throw new Error('Aluno não encontrado');
    }
    const whatsapp = alunoData.whatsapp;
    console.log('[PROPOR REFEIÇÃO v3.0] 📱 WhatsApp:', whatsapp);
    // ========================================
    // CRIAR REGISTRO PENDENTE
    // ========================================
    console.log('[PROPOR REFEIÇÃO v3.0] 💾 Criando registro pendente...');
    const liquidos_ml = typeof liquidos === 'number' ? liquidos * 1000 : liquidos;
    const { data: registroData, error: registroError } = await supabase.from('daily_consumption_history').insert({
      aluno_id: aluno_id,
      data_registro: new Date().toISOString().split('T')[0],
      consumo_calorias: 0,
      consumo_proteina: 0,
      consumo_carboidrato: 0,
      consumo_gordura: 0,
      consumo_agua_ml: 0,
      analise_qualitativa: 'AGUARDANDO_CONFIRMACAO',
      confirmada: false
    }).select('id').single();
    if (registroError) {
      console.error('[PROPOR REFEIÇÃO v3.0] ❌ Erro ao criar registro:', registroError);
      throw new Error(`Erro ao criar registro: ${registroError.message}`);
    }
    const registro_id = registroData.id;
    console.log('[PROPOR REFEIÇÃO v3.0] ✅ Registro criado:', registro_id);
    // ========================================
    // OBTER HORÁRIO ATUAL
    // ========================================
    const horario_atual = new Date().toLocaleTimeString('pt-BR', {
      timeZone: 'America/Sao_Paulo',
      hour: '2-digit',
      minute: '2-digit'
    });
    // ========================================
    // CONSTRUIR MENSAGEM
    // ========================================
    const mensagem_texto = `🍽️ Confirmar Refeição - ${tipo.toUpperCase()}

📋 O QUE VOCÊ COMEU:
${refeicao}

📊 RESUMO NUTRICIONAL:
- Calorias: ${calorias} kcal
- Proteínas: ${proteinas}g
- Carboidratos: ${carboidratos}g
- Gorduras: ${gorduras}g
- Líquidos: ${liquidos_ml}ml

Confirmar este registro?`;
    // ========================================
    // PREPARAR PAYLOADS DOS BOTÕES
    // ========================================
    const payload_sim = {
      action: 'confirmar_registro_refeicao',
      registro_id: registro_id,
      aluno_id: aluno_id,
      refeicao: refeicao,
      tipo: tipo,
      horario: horario_atual,
      calorias: calorias,
      proteinas: proteinas,
      carboidratos: carboidratos,
      gorduras: gorduras,
      liquidos_ml: liquidos_ml
    };
    const payload_nao = {
      action: 'cancelar_registro_refeicao',
      registro_id: registro_id,
      aluno_id: aluno_id
    };
    console.log('[PROPOR REFEIÇÃO v3.0] ✅ Payloads criados');
    // ========================================
    // SALVAR EM AGUARDANDO_CONFIRMACAO
    // ========================================
    console.log('[PROPOR REFEIÇÃO v3.0] 💾 Salvando em aguardando_confirmacao...');
    const aguardando_confirmacao_data = {
      aguardando: true,
      tipo: 'registro_refeicao',
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      registro_id: registro_id,
      button_payload_sim: payload_sim,
      button_payload_nao: payload_nao,
      timestamp: new Date().toISOString()
    };
    const { error: updateError } = await supabase.from('alunos').update({
      aguardando_confirmacao: aguardando_confirmacao_data
    }).eq('id', aluno_id);
    if (updateError) {
      console.error('[PROPOR REFEIÇÃO v3.0] ❌ Erro ao salvar aguardando_confirmacao:', updateError);
      throw new Error(`Erro ao salvar bloqueio: ${updateError.message}`);
    }
    console.log('[PROPOR REFEIÇÃO v3.0] ✅ Bloqueio salvo');
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
    console.log('[PROPOR REFEIÇÃO v3.0] 📤 Enviando botão...');
    const api_url = `https://us.api-wa.me/${api_key}/message/button_reply`;
    const request_body = {
      to: whatsapp,
      header: {
        title: '🍽️ Registro de Refeição'
      },
      text: mensagem_texto,
      footer: 'Escolha uma opção:',
      buttons: [
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_sim),
          text: '✅ Sim, registrar!'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_nao),
          text: '❌ Não, alterar'
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
    console.log('[PROPOR REFEIÇÃO v3.0] ✅ Botão enviado com sucesso');
    // ========================================
    // RETORNAR SUCESSO
    // ========================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta de registro enviada ao aluno',
      detalhes: {
        registro_id: registro_id,
        tipo_refeicao: tipo,
        calorias: calorias,
        whatsapp: whatsapp,
        horario: horario_atual,
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
    console.error('[PROPOR REFEIÇÃO v3.0] ❌ ERRO:', error.message);
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
