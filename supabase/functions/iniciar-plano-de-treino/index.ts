/**
 * @name iniciar-plano-de-treino
 * @version 3.2.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-09
 *
 * @description
 * Edge Function (Orquestrador da ETAPA 1)
 *
 * @changelog
 * - v3.2.0:
 * - CORREÇÃO (CRÍTICA): Corrigido o erro 'Invalid value: "system"'.
 * - A API 'v1/responses' (usada pelos helpers) não aceita 'type: "system"'.
 * - O 'conversation_history' foi reformatado para o schema correto
 * da API 'v1/responses', que é:
 * { type: "message", role: "system", content: [{ type: "output_text", ... }] }
 * { type: "message", role: "user", content: [{ type: "output_text", ... }] }
 * - O loop de retentativas também foi atualizado para usar este formato.
 * - v3.1.0:
 * - Corrigido o erro 'Unknown parameter: "system_prompt"'.
 * - v3.0.0:
 * - Reconstrução total para ser um orquestrador com loop de 3 tentativas.
 *
 * @workflow
 * (Permanece o mesmo da v3.1)
 */ // Importa os helpers padrão
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// Configurações padrão
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-5";
// Helper 'j' simplificado para respostas JSON
function j(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
/**
 * Valida os argumentos retornados pela LLM (Etapa 1).
 * (Não modificado)
 */ function validarArgumentosEtapa1(args) {
  if (!args) return false;
  const { nome, objetivo, frequencia_semanal_dias, programas_de_treino } = args;
  if (!nome || !objetivo || !frequencia_semanal_dias || !programas_de_treino) {
    return false;
  }
  if (!Array.isArray(programas_de_treino) || programas_de_treino.length === 0) {
    return false;
  }
  const primeiroPrograma = programas_de_treino[0];
  if (!primeiroPrograma.nome_programa || !primeiroPrograma.dia_da_semana) {
    return false;
  }
  return true;
}
serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  const startedAt = new Date().toISOString();
  try {
    const body = await req.json().catch(()=>({}));
    // 1. Receber payload (Input do Usuário/Painel)
    const { aluno_id, input_texto } = body;
    console.log("[INICIAR-PLANO v3.2] ▶️ Start (Orquestrador Etapa 1)", {
      startedAt,
      aluno_id
    });
    // Validação de segurança básica
    if (!SUPABASE_URL || !SERVICE_ROLE || !OPENAI_API_KEY) {
      throw new Error("Env Supabase ou OpenAI ausente");
    }
    if (!aluno_id || !input_texto) {
      throw new Error("Payload incompleto (aluno_id ou input_texto)");
    }
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // 2. Buscar o Prompt da 'prompts_sistema'
    const CHAVE_PROMPT = 'criar_programas_treino';
    console.log(`[INICIAR-PLANO v3.2] 🔍 Buscando prompt: ${CHAVE_PROMPT}`);
    const { data: promptData, error: promptErr } = await supabase.from("prompts_sistema").select("prompt_base, functions_jsonb").eq("chave", CHAVE_PROMPT).single();
    if (promptErr) throw new Error(`Erro ao buscar prompt: ${promptErr.message}`);
    if (!promptData) throw new Error(`Prompt '${CHAVE_PROMPT}' não encontrado na tabela 'prompts_sistema'.`);
    const { prompt_base, functions_jsonb } = promptData;
    if (!prompt_base || !functions_jsonb) {
      throw new Error(`Prompt '${CHAVE_PROMPT}' está mal configurado (prompt_final ou functions_jsonb estão nulos).`);
    }
    // 3. Loop de 3 Retentativas (Como solicitado)
    const MAX_TENTATIVAS = 3;
    // ⬇️⬇️⬇️ LÓGICA DO HISTÓRICO CORRIGIDA (v3.2.0) ⬇️⬇️⬇️
    // Este é o formato que a API 'v1/responses' (usada nos seus helpers)
    // espera, baseado no erro 'Invalid value: "system"'.
    let conversation_history = [
      {
        type: "message",
        role: "system",
        content: [
          {
            type: "output_text",
            text: prompt_base
          }
        ]
      },
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "output_text",
            text: input_texto
          }
        ]
      }
    ];
    // ⬆️⬆️⬆️ FIM DA CORREÇÃO ⬆️⬆️⬆️
    let last_conversation_id = null;
    let last_tool_call_id = null;
    let argumentos_validos = null;
    for(let i = 1; i <= MAX_TENTATIVAS; i++){
      console.log(`[INICIAR-PLANO v3.2] 🤖 Chamada OpenAI (Tentativa ${i}/${MAX_TENTATIVAS})...`);
      const openaiPayload = {
        model: OPENAI_MODEL,
        input: conversation_history,
        tools: functions_jsonb,
        tool_choice: "any",
        store: true,
        ...last_conversation_id && {
          conversation: last_conversation_id
        }
      };
      const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(openaiPayload)
      });
      if (!openaiResponse.ok) {
        // Este 'throw' será pego pelo "Super-Catch" no final
        throw new Error(`Erro OpenAI: ${await openaiResponse.text()}`);
      }
      const responseData = await openaiResponse.json();
      last_conversation_id = responseData.conversation_id;
      const output = responseData.output?.[0];
      if (output?.type === 'function_call') {
        const tool_args = JSON.parse(output.arguments || "{}");
        if (validarArgumentosEtapa1(tool_args)) {
          // SUCESSO!
          console.log(`[INICIAR-PLANO v3.2] ✅ Sucesso na Tentativa ${i}. Tool call válida recebida.`);
          last_tool_call_id = output.call_id;
          argumentos_validos = tool_args;
          break; // Sai do loop
        } else {
          // ERRO (Loop): Tool call com argumentos vazios
          console.warn(`[INICIAR-PLANO v3.2] ⚠️ Tentativa ${i} falhou: Tool call com argumentos vazios/inválidos.`);
          // ⬇️⬇️⬇️ LÓGICA DE CORREÇÃO (v3.2.0) ⬇️⬇️⬇️
          conversation_history.push(output, {
            type: "message",
            role: "user",
            content: [
              {
                type: "output_text",
                text: "Você acionou a ferramenta, porém ela veio vazia ou incompleta. Por favor, Releia o texto original e traga TODAS as informações necessárias (nome, objetivo, frequencia_semanal_dias, programas_de_treino)."
              }
            ]
          });
        }
      } else {
        // ERRO (Loop): IA não chamou a ferramenta
        console.warn(`[INICIAR-PLANO v3.2] ⚠️ Tentativa ${i} falhou: IA não chamou a ferramenta.`);
        // ⬇️⬇️⬇️ LÓGICA DE CORREÇÃO (v3.2.0) ⬇️⬇️⬇️
        conversation_history.push(output, {
          type: "message",
          role: "user",
          content: [
            {
              type: "output_text",
              text: "Você precisa analisar e devolver os parâmetros através do function calling. Por favor, use a ferramenta 'iniciar_novo_plano_de_treino'."
            }
          ]
        });
      }
    } // Fim do loop 'for'
    // 4. Verificar se o Loop Falhou
    if (!argumentos_validos) {
      console.error("[INICIAR-PLANO v3.2] 💥 FALHA: IA não retornou uma tool call válida após 3 tentativas.");
      throw new Error("Falha na Etapa 1: A IA não conseguiu gerar os parâmetros do plano de treino após 3 tentativas.");
    }
    // 5. Chamar a RPC (v2.0) [cite: fn_iniciar_novo_plano_de_treino.sql]
    console.log(`[INICIAR-PLANO v3.2] 🛠️ Chamando RPC 'iniciar_novo_plano_de_treino' (v2.0)...`);
    const { nome, objetivo, frequencia_semanal_dias, programas_de_treino } = argumentos_validos;
    const { data: rpcData, error: rpcError } = await supabase.rpc("iniciar_novo_plano_de_treino", {
      p_aluno_id: aluno_id,
      p_nome_programa: nome,
      p_objetivo: objetivo,
      p_frequencia: frequencia_semanal_dias,
      p_programas_json: programas_de_treino
    });
    if (rpcError) {
      console.error("[INICIAR-PLANO v3.2] 💥 Erro na RPC", rpcError);
      throw new Error(`Falha ao salvar plano no banco: ${rpcError.message}`);
    }
    console.log(`[INICIAR-PLANO v3.2] 📥 RPC OK. ${rpcData.length} treinos da semana criados.`);
    // 6. Retornar 200 OK com os dados para a ETAPA 2
    return j({
      success: true,
      message: "Etapa 1 (Início do Plano) concluída. IDs dos treinos da semana retornados.",
      // Dados para a Etapa 2
      conversation_id: last_conversation_id,
      tool_call_id_etapa_1: last_tool_call_id,
      programas_criados: rpcData,
      startedAt,
      finishedAt: new Date().toISOString()
    });
  } catch (e) {
    // ========================================
    // ⬇️⬇️⬇️ "SUPER-CATCH" (Simplificado) ⬇️⬇️⬇️
    // ========================================
    console.error("[INICIAR-PLANO v3.2] 💥 Erro inesperado (Super-Catch)", e);
    return j({
      error: String(e?.message ?? e),
      instrucao: "Falha na Etapa 1 (iniciar-plano-de-treino)."
    }, 500);
  }
});
