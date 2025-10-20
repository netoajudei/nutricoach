/**
 * @name propor-registro-refeicao
 * @version 1.2.0 (Restaurada)
 * @description
 * Cria registro COM VALORES REAIS (corrigido tipos numéricos)
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
    console.log('[PROPOR REFEIÇÃO] ========================================');
    console.log('[PROPOR REFEIÇÃO] 🚀 Iniciando função');
    const body = await req.json();
    console.log('[PROPOR REFEIÇÃO] 📦 Payload recebido:', JSON.stringify(body, null, 2));
    const { aluno_id, refeicao, tipo, calorias, proteinas, carboidratos, gorduras, liquidos_ml } = body;
    if (!aluno_id || !refeicao || !tipo) {
      throw new Error('Parâmetros obrigatórios faltando: aluno_id, refeicao, tipo');
    }
    console.log('[PROPOR REFEIÇÃO] ✅ Validação de parâmetros OK');
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !aluno) {
      console.error('[PROPOR REFEIÇÃO] ❌ Erro ao buscar aluno:', alunoError);
      throw new Error(`Aluno não encontrado. ID: ${aluno_id}`);
    }
    console.log('[PROPOR REFEIÇÃO] ✅ WhatsApp encontrado:', aluno.whatsapp);
    const horario_atual = new Intl.DateTimeFormat('pt-BR', {
      timeZone: 'America/Sao_Paulo',
      hour: '2-digit',
      minute: '2-digit'
    }).format(new Date());
    console.log('[PROPOR REFEIÇÃO] ⏰ Horário:', horario_atual);
    // ========================================
    // CRIAR REGISTRO COM VALORES REAIS
    // ========================================
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
      console.error('[PROPOR REFEIÇÃO] ❌ Erro ao criar registro:', registroError);
      throw new Error(`Erro ao criar registro: ${registroError.message}`);
    }
    const registro_id = registroData.id;
    console.log('[PROPOR REFEIÇÃO] ✅ Registro criado com ID:', registro_id);
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
    console.log('[PROPOR REFEIÇÃO] 🔑 Buscando WAME_API_KEY...');
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError || !configData) {
      console.error('[PROPOR REFEIÇÃO] ❌ Erro ao buscar API key:', configError);
      throw new Error('WAME_API_KEY não encontrada em config_sistema');
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
    console.log('[PROPOR REFEIÇÃO] 📡 Enviando requisição para WAME...');
    const wameResponse = await fetch(api_url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(request_body)
    });
    console.log('[PROPOR REFEIÇÃO] 📊 Status da resposta:', wameResponse.status);
    const responseBody = await wameResponse.text();
    if (!wameResponse.ok) {
      console.error('[PROPOR REFEIÇÃO] ❌ Erro na API WAME');
      throw new Error(`[WAME] Erro ${wameResponse.status}: ${responseBody}`);
    }
    console.log('[PROPOR REFEIÇÃO] ✅ Mensagem enviada com sucesso!');
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta de registro enviada ao aluno',
      detalhes: {
        registro_id: registro_id,
        tipo_refeicao: tipo,
        whatsapp: aluno.whatsapp,
        horario: horario_atual
      }
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROPOR REFEIÇÃO] 💥 ERRO FATAL:', error.message);
    console.error('[PROPOR REFEIÇÃO] 💥 Stack:', error.stack);
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
