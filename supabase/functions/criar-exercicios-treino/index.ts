/**
 * @name criar-exercicios-treino
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-09
 * @lastModified 2025-11-09T06:50:00-03:00
 *
 * @description
 * Edge Function (Orquestrador da ETAPA 2 - Criação de Exercícios)
 * 
 * Esta função é chamada automaticamente após o sucesso de iniciar-plano-de-treino.
 * Recebe a lista de program_workouts criados (id, dia_da_semana, nome_treino) e
 * utiliza a OpenAI para gerar os exercícios específicos de cada treino.
 *
 * @workflow
 * 1. Recebe: { programas_criados: array, input_texto: string }
 * 2. Busca prompt 'criar_exercicios' do banco
 * 3. Substitui {{programasdetreino}} pela tabela de programas
 * 4. Cria NOVA conversation (independente da Etapa 1)
 * 5. Loop de até 3 tentativas com OpenAI
 * 6. Valida array de exercícios retornado
 * 7. Insere exercícios na tabela workout_exercises
 * 8. Retorna sucesso com contador
 *
 * @input
 * - programas_criados: Array<{ id: UUID, dia_da_semana: number, nome_treino: string }>
 * - input_texto: string (texto original do usuário para contexto)
 *
 * @output
 * - success: boolean
 * - exercicios_inseridos: number
 * - conversation_id: string (novo conversation criado)
 *
 * @toolCall esperado
 * {
 *   "exercicios": [
 *     {
 *       "nome_exercicio_oficial": string,
 *       "id_exercicio_template": number,
 *       "program_id": UUID,
 *       "series": string,
 *       "repeticoes": string,
 *       "descanso": string,
 *       "observacoes": string
 *     }
 *   ]
 * }
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4.1";
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
function validarArgumentos(args) {
  if (!args || !Array.isArray(args.exercicios) || args.exercicios.length === 0) {
    return false;
  }
  const primeiro = args.exercicios[0];
  return !!(primeiro.program_id && primeiro.id_exercicio_template);
}
serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  const startedAt = new Date().toISOString();
  console.log(`[CRIAR-EXERCICIOS] 🚀 Início: ${startedAt}`);
  try {
    const body = await req.json().catch(()=>({}));
    const { programas_criados } = body;
    if (!programas_criados || !Array.isArray(programas_criados)) {
      throw new Error("programas_criados ausente ou inválido");
    }
    console.log(`[1] ✅ ${programas_criados.length} programas recebidos`);
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // Buscar prompt
    console.log(`[2] 🔍 Buscando prompt: criar_exercicios`);
    const { data: promptData, error: promptErr } = await supabase.from("prompts_sistema").select("prompt_base, functions_jsonb").eq("chave", "criar_exercicios").maybeSingle();
    if (promptErr || !promptData) {
      throw new Error(`Prompt criar_exercicios não encontrado: ${promptErr?.message}`);
    }
    console.log(`[2] ✅ Prompt encontrado (${promptData.prompt_base.length} chars)`);
    // Montar tabela
    let tabela = "\n| ID | Dia | Nome do Treino |\n|---|---|---|\n";
    for (const p of programas_criados){
      tabela += `| ${p.id} | ${p.dia_da_semana} | ${p.nome_treino} |\n`;
    }
    const prompt_final = promptData.prompt_base.replace("{{programasdetreino}}", tabela);
    console.log(`[3] ✅ Prompt preparado (${prompt_final.length} chars)`);
    // ============================================
    // ETAPA 4: CRIAR NOVO CONVERSATION
    // ============================================
    console.log(`[4] 🆕 Criando novo conversation (independente da Etapa 1)...`);
    const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        metadata: {
          tipo: 'criar_exercicios'
        }
      })
    });
    if (!createConvResponse.ok) {
      throw new Error(`Erro ao criar conversation: ${await createConvResponse.text()}`);
    }
    const convData = await createConvResponse.json();
    let conversation_id = convData.id;
    console.log(`[4] ✅ Conversation criado: ${conversation_id}`);
    // ============================================
    // ETAPA 5: LOOP DE TENTATIVAS
    // ============================================
    let conversation_history = [
      {
        type: "message",
        role: "system",
        content: [
          {
            type: "input_text",
            text: prompt_final
          }
        ]
      }
    ];
    let argumentos_validos = null;
    console.log(`[5] 🔄 Iniciando loop de tentativas...`);
    for(let i = 1; i <= 3; i++){
      console.log(`[TENTATIVA ${i}] 🤖 Chamando OpenAI...`);
      const payload = {
        model: OPENAI_MODEL,
        input: conversation_history,
        tools: promptData.functions_jsonb,
        tool_choice: "required",
        store: true,
        conversation: conversation_id
      };
      const res = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(payload)
      });
      if (!res.ok) {
        throw new Error(`OpenAI HTTP ${res.status}: ${await res.text()}`);
      }
      const data = await res.json();
      conversation_id = data.conversation_id;
      const output = data.output?.[0];
      console.log(`[TENTATIVA ${i}] ✅ Response: ${data.id}`);
      if (output?.type === 'function_call') {
        const args = JSON.parse(output.arguments || "{}");
        console.log(`[TENTATIVA ${i}] 🔧 Tool: ${output.name}`);
        console.log(`[TENTATIVA ${i}] 📥 Exercícios: ${args.exercicios?.length || 0}`);
        if (validarArgumentos(args)) {
          console.log(`[TENTATIVA ${i}] ✅ SUCESSO`);
          argumentos_validos = args;
          break;
        }
        console.log(`[TENTATIVA ${i}] ⚠️ Argumentos inválidos`);
        conversation_history.push(output, {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "Argumentos incompletos. Retorne o array exercicios com todos os campos."
            }
          ]
        });
      } else {
        console.log(`[TENTATIVA ${i}] ⚠️ Sem tool call`);
        conversation_history.push(output, {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "Use a ferramenta disponível para retornar os exercícios."
            }
          ]
        });
      }
    }
    if (!argumentos_validos) {
      throw new Error("IA não retornou exercícios após 3 tentativas");
    }
    console.log(`[6] ✅ ${argumentos_validos.exercicios.length} exercícios extraídos`);
    // ============================================
    // ETAPA 7: INSERIR EXERCÍCIOS
    // ============================================
    console.log(`[7] 💾 Inserindo exercícios no banco...`);
    const exercicios = argumentos_validos.exercicios;
    let contador = 0;
    for (const ex of exercicios){
      const { error: insertErr } = await supabase.from("workout_exercises").insert({
        workout_id: ex.program_id,
        ordem: contador + 1,
        nome_exercicio: ex.nome_exercicio_oficial,
        exercicio_template_id: ex.id_exercicio_template,
        series: ex.series,
        repeticoes: ex.repeticoes,
        descanso_segundos: ex.descanso ? parseInt(ex.descanso) : null,
        observacoes: ex.observacoes || null,
        grupo_muscular: null // preenchido via trigger
      });
      if (insertErr) {
        console.error(`[ERRO] Exercício ${contador + 1}:`, insertErr.message);
      } else {
        contador++;
      }
    }
    console.log(`[7] ✅ ${contador}/${exercicios.length} exercícios inseridos com sucesso`);
    const finishedAt = new Date().toISOString();
    console.log(`[8] 🎉 Concluído em: ${finishedAt}\n`);
    return jsonResponse({
      success: true,
      exercicios_inseridos: contador,
      conversation_id,
      timing: {
        started_at: startedAt,
        finished_at: finishedAt
      }
    });
  } catch (error) {
    console.error(`[ERRO] ${error.message}`);
    return jsonResponse({
      error: error.message
    }, 500);
  }
});
