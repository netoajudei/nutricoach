/**
 * @name propor-atualizacao-carga
 * @version 1.0.0
 * @author NutriCoach AI Development
 * @date 2025-10-15
 *
 * @description
 * Esta função é acionada pelo `orquestrador-ia` após uma `tool call`
 * que identifica uma variação de carga em um exercício. A função calcula o
 * novo peso, constrói uma mensagem de confirmação contextual e a envia
 * ao aluno com botões de "Sim" e "Não" via WhatsApp.
 *
 * @endpoint POST /functions/v1/propor-atualizacao-carga
 *
 * @param {object} body
 * @param {string} body.exercicio_id - O ID do exercício a ser atualizado.
 * @param {number} body.variacao_kg - A variação de peso (positiva ou negativa).
 *
 * @returns {Response} Uma resposta de sucesso ou erro.
 */ /**
 * @name propor-atualizacao-carga
 * @version 1.0.1
 * @description
 * Envia uma proposta de atualização de carga com botões para o aluno.
 *
 * @changelog
 * - v1.0.1: Adicionado o campo obrigatório `header` na chamada da API
 * de botões da `wa.me`, corrigindo o erro de validação 400.
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
    const { exercicio_id, variacao_kg } = await req.json();
    if (!exercicio_id || variacao_kg === undefined) {
      throw new Error("Parâmetros `exercicio_id` e `variacao_kg` são obrigatórios.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: dadosExercicio, error: fetchError } = await supabase.from('workout_exercises').select(`
        nome_exercicio,
        carga_kg,
        program_workouts (
          workout_programs (
            aluno_id,
            alunos ( whatsapp )
          )
        )
      `).eq('id', exercicio_id).single();
    if (fetchError || !dadosExercicio) {
      throw new Error(`Exercício com ID ${exercicio_id} não encontrado: ${fetchError?.message}`);
    }
    const nomeExercicio = dadosExercicio.nome_exercicio;
    const cargaAtual = dadosExercicio.carga_kg;
    const alunoWhatsapp = dadosExercicio.program_workouts?.workout_programs?.alunos?.whatsapp;
    if (!alunoWhatsapp) {
      throw new Error("Não foi possível encontrar o número de WhatsApp do aluno.");
    }
    const nova_carga = cargaAtual + variacao_kg;
    let textoMensagem = '';
    if (variacao_kg > 0) {
      textoMensagem = `Notei que você progrediu no exercício *${nomeExercicio}*! 💪\n\nDeseja atualizar a carga de ${cargaAtual}kg para **${nova_carga}kg** no seu plano para os próximos treinos?`;
    } else {
      textoMensagem = `Notei que você ajustou a carga no exercício *${nomeExercicio}*.\n\nDeseja reduzir a carga de ${cargaAtual}kg para **${nova_carga}kg** no seu plano?`;
    }
    const yesPayload = JSON.stringify({
      action: "confirmar_update_carga",
      exercicio_id: exercicio_id,
      nova_carga: nova_carga
    });
    const noPayload = JSON.stringify({
      action: "cancelar_update_carga",
      exercicio_id: exercicio_id
    });
    const apiKey = Deno.env.get('WAME_API_KEY');
    if (!apiKey) throw new Error("Variável de ambiente WAME_API_KEY não configurada.");
    const apiUrl = `https://us.api-wa.me/${apiKey}/message/button_reply`;
    const payload = {
      to: alunoWhatsapp,
      // <<-- CORREÇÃO AQUI -->>
      header: {
        title: "Confirmação de Progresso 🚀" // Adiciona o cabeçalho obrigatório
      },
      text: textoMensagem,
      footer: "Escolha uma opção:",
      buttons: [
        {
          type: "quick_reply",
          id: yesPayload,
          text: "Sim, atualizar!"
        },
        {
          type: "quick_reply",
          id: noPayload,
          text: "Não, manter"
        }
      ]
    };
    console.log(`[Propor Carga] Enviando proposta de atualização para ${alunoWhatsapp}...`);
    const response = await fetch(apiUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    if (!response.ok) {
      throw new Error(`[WAME] Erro ao enviar mensagem com botão: ${await response.text()}`);
    }
    return new Response(JSON.stringify({
      success: true,
      message: "Proposta de atualização enviada ao aluno."
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error("🔥 Erro na função propor-atualizacao-carga:", error.message);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
