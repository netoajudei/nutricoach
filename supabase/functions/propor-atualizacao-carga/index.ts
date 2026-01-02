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
/**
 * @name propor-atualizacao-carga
 * @version 5.0.0
 * @author NutriCoach AI Development Team
 * @description
 * Edge Function ADAPTADA para receber logs completos de treino (Carga, Series, Repetições).
 * Formata mensagem de confirmação para log de exercício.
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
    console.log('[PROPOR LOG v5.0] 🚀 Iniciando');
    const { aluno_id, conversation_id, tool_call_id, argumentos } = await req.json();
    // ========================================
    // 1. VALIDAÇÕES BÁSICAS
    // ========================================
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error('Parâmetros obrigatórios faltando: aluno_id, conversation_id, tool_call_id, argumentos');
    }
    // ADAPTAÇÃO: Lendo os novos argumentos misturados
    // O ID pode vir como id_exercicio ou exercicio_id, garantimos pegar um deles
    const id_exercicio_real = argumentos.id_exercicio || argumentos.exercicio_id;
    const { nome_exercicio, carga_levantada, quant_series, quant_repeticoes } = argumentos;
    if (!id_exercicio_real || !carga_levantada || !quant_series || !quant_repeticoes) {
      throw new Error('Argumentos incompletos: Faltando id, carga, séries ou repetições.');
    }
    console.log('[PROPOR LOG v5.0] 📋 Dados recebidos:');
    console.log(`- Exercício: ${nome_exercicio} (ID: ${id_exercicio_real})`);
    console.log(`- Execução: ${quant_series}x${quant_repeticoes} com ${carga_levantada}kg`);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // 2. BUSCAR DADOS COMPLEMENTARES (WHATSAPP)
    // ========================================
    // Mantemos a busca do aluno para pegar o WhatsApp correto e validar existência
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError || !alunoData) {
      throw new Error('Aluno não encontrado');
    }
    const whatsapp = alunoData.whatsapp;
    // Opcional: Validar se exercício existe (apenas para garantir integridade)
    const { data: exercicioCheck, error: exError } = await supabase.from('workout_exercises').select('nome_exercicio').eq('id', id_exercicio_real).single();
    // Se o nome vier vazio no argumento, usamos do banco
    const nomeFinal = nome_exercicio || exercicioCheck?.nome_exercicio || "Exercício";
    // ========================================
    // 3. CONSTRUIR MENSAGEM (LAYOUT NOVO)
    // ========================================
    const mensagem_texto = `📝 *Registro de Atividade Detectado*

Opa! Identifiquei que você acabou de realizar o exercício:
💪 *${nomeFinal}*

📊 *Detalhes da Execução:*
• *Séries:* ${quant_series}
• *Repetições:* ${quant_repeticoes}
• *Carga:* ${carga_levantada} kg

Deseja salvar esse registro no seu histórico de progresso? 🚀`;
    // ========================================
    // 4. PREPARAR PAYLOADS DOS BOTÕES
    // ========================================
    const botao_id = crypto.randomUUID();
    // Payload do botão SIM carrega os dados para a próxima função salvar
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
    // ========================================
    // 5. REGISTRAR BOTÃO NO BANCO (UPSERT)
    // ========================================
    console.log('[PROPOR LOG v5.0] 💾 Registrando botão ativo...');
    // ADAPTAÇÃO: Salvamos os dados EXATOS que precisamos para criar o log depois
    const { error: botaoError } = await supabase.from('botoes_ativos').upsert({
      id: botao_id,
      aluno_id: aluno_id,
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      tipo_acao: 'registrar_log_exercicio',
      argumentos: {
        exercicio_id: id_exercicio_real,
        nome_exercicio: nomeFinal,
        carga_kg: carga_levantada,
        series: quant_series,
        repeticoes: quant_repeticoes,
        whatsapp: whatsapp
      },
      edge_function: 'registrar-log-treino' // Aponte para a função que cria o log (aquela que deletamos para recriar depois)
    }, {
      onConflict: 'aluno_id'
    });
    if (botaoError) {
      console.error('[PROPOR LOG v5.0] ❌ Erro ao registrar botão:', botaoError);
      throw new Error(`Erro ao registrar botão: ${botaoError.message}`);
    }
    // ========================================
    // 6. BUSCAR API KEY E ENVIAR WHATSAPP
    // ========================================
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError || !configData) {
      throw new Error('WAME_API_KEY não encontrada');
    }
    const api_key = configData.valor;
    console.log('[PROPOR LOG v5.0] 📤 Enviando botão...');
    const api_url = `https://us.api-wa.me/${api_key}/message/button_reply`;
    const request_body = {
      to: whatsapp,
      header: {
        title: '📊 Confirmação de Treino'
      },
      text: mensagem_texto,
      footer: 'Confirme os dados:',
      buttons: [
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_sim),
          text: '✅ Sim, Salvar'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify(payload_nao),
          text: '❌ Cancelar'
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
    console.log('[PROPOR LOG v5.0] ✅ Botão enviado com sucesso');
    return new Response(JSON.stringify({
      success: true,
      message: 'Proposta de log enviada ao aluno',
      detalhes: {
        exercicio: nomeFinal,
        carga: carga_levantada
      }
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[PROPOR LOG v5.0] ❌ ERRO:', error.message);
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
