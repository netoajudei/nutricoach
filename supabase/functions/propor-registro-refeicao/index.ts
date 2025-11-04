/**
 * @name propor-registro-refeicao
 * @version 2.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 00:59:00 -03:00
 * 
 * @description
 * Edge Function que propõe o registro de uma refeição ao aluno via WhatsApp
 * com botões de confirmação. Cria o registro pendente no banco e ativa o
 * sistema de bloqueio educado.
 * 
 * @workflow
 * 1. Recebe dados da refeição do orquestrador (incluindo conversation_id e tool_call_id)
 * 2. Cria registro pendente em daily_consumption_history (confirmada: false)
 * 3. Envia botão de confirmação via WhatsApp (WAME API)
 * 4. SALVA estado de bloqueio em alunos.aguardando_confirmacao
 * 5. Retorna sucesso
 * 
 * @changelog
 * - v2.0.0 (2025-11-04): Implementado sistema de bloqueio educado
 *   - Adicionado recebimento de conversation_id e tool_call_id do orquestrador
 *   - Implementado salvamento de estado em aguardando_confirmacao
 *   - Payloads dos botões agora salvos para reenvio posterior
 *   - Bloqueio ativado até confirmação/cancelamento do usuário
 * 
 * @param {string} aluno_id - ID do aluno
 * @param {string} refeicao - Descrição da refeição
 * @param {string} tipo - Tipo da refeição (café, almoço, jantar, etc)
 * @param {number} calorias - Total de calorias
 * @param {number} proteinas - Gramas de proteína
 * @param {number} carboidratos - Gramas de carboidratos
 * @param {number} gorduras - Gramas de gorduras
 * @param {number} liquidos_ml - Mililitros de líquidos
 * @param {string} conversation_id - ID da conversation OpenAI (NOVO)
 * @param {string} tool_call_id - ID do tool call OpenAI (NOVO)
 * 
 * @returns {object} { success, message, registro_id }
 * 
 * @security
 * - Usa SUPABASE_SERVICE_ROLE_KEY
 * - API key WAME buscada de config_sistema
 * 
 * @dependencies
 * - Supabase Client
 * - WAME API (button_reply endpoint)
 * - Tabelas: alunos, daily_consumption_history, config_sistema
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
    console.log('[PROPOR REFEIÇÃO] 🚀 Iniciando função');
    const body = await req.json();
    const { aluno_id, refeicao, tipo, calorias, proteinas, carboidratos, gorduras, liquidos_ml, conversation_id, tool_call_id } = body;
    if (!aluno_id || !refeicao || !tipo) {
      throw new Error('Parâmetros obrigatórios faltando');
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !aluno) {
      throw new Error(`Aluno não encontrado`);
    }
    const horario_atual = new Intl.DateTimeFormat('pt-BR', {
      timeZone: 'America/Sao_Paulo',
      hour: '2-digit',
      minute: '2-digit'
    }).format(new Date());
    console.log('[PROPOR REFEIÇÃO] 💾 Criando registro...');
    const { data: registroData, error: registroError } = await supabase.from('daily_consumption_history').insert({
      aluno_id: aluno_id,
      data_registro: new Date().toISOString().split('T')[0],
      consumo_calorias: Math.round(calorias || 0),
      consumo_proteina: Math.round(proteinas || 0),
      consumo_carboidrato: Math.round(carboidratos || 0),
      consumo_gordura: Math.round(gorduras || 0),
      consumo_agua_ml: Math.round(liquidos_ml || 0),
      analise_qualitativa: refeicao,
      confirmada: false
    }).select('id').single();
    if (registroError) {
      throw new Error(`Erro ao criar registro: ${registroError.message}`);
    }
    const registro_id = registroData.id;
    console.log('[PROPOR REFEIÇÃO] ✅ Registro criado:', registro_id);
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
    const payload_sim = JSON.stringify({
      action: 'confirmar_registro_refeicao',
      registro_id: registro_id,
      aluno_id: aluno_id
    });
    const payload_nao = JSON.stringify({
      action: 'cancelar_registro_refeicao',
      registro_id: registro_id,
      aluno_id: aluno_id
    });
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError || !configData) {
      throw new Error('WAME_API_KEY não encontrada');
    }
    const api_key = configData.valor;
    const api_url = `https://us.api-wa.me/${api_key}/message/button_reply`;
    const request_body = {
      to: aluno.whatsapp,
      header: {
        title: '🍽️ Registro de Refeição'
      },
      text: mensagem_texto,
      footer: 'Escolha uma opção:',
      buttons: [
        {
          type: 'quick_reply',
          id: payload_sim,
          text: 'Sim, registrar!'
        },
        {
          type: 'quick_reply',
          id: payload_nao,
          text: 'Não, alterar'
        }
      ]
    };
    console.log('[PROPOR REFEIÇÃO] 📡 Enviando botão...');
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
    console.log('[PROPOR REFEIÇÃO] 💾 Salvando estado de bloqueio...');
    await supabase.from('alunos').update({
      aguardando_confirmacao: {
        aguardando: true,
        conversation_id: conversation_id,
        tool_call_id: tool_call_id,
        button_payload_sim: {
          action: 'confirmar_registro_refeicao',
          registro_id: registro_id,
          aluno_id: aluno_id
        },
        button_payload_nao: {
          action: 'cancelar_registro_refeicao',
          registro_id: registro_id,
          aluno_id: aluno_id
        },
        created_at: new Date().toISOString()
      }
    }).eq('id', aluno_id);
    console.log('[PROPOR REFEIÇÃO] ✅ Bloqueio ativado');
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta enviada e bloqueio ativado',
      registro_id: registro_id
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROPOR REFEIÇÃO] ❌ ERRO:', error.message);
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
