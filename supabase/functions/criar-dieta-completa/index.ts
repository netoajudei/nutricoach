/**
 * @name criar-dieta-completa
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-09
 * @lastModified 2025-11-09T09:00:00-03:00
 *
 * @description
 * Edge Function para criar plano alimentar completo.
 * Recebe 2 tool calls da OpenAI (macros_totais e dieta) e chama
 * Edge Function para processar e finalizar.
 *
 * @workflow
 * 1. Recebe: { aluno_id, mensagem_nutricionista }
 * 2. Busca/cria conversation_id em instrucoes_nutricionista
 * 3. Busca prompt 'criar_dieta' (prompt_base + functions_jsonb)
 * 4. Envia para OpenAI com as ferramentas
 * 5. Detecta 2 tool calls no output
 * 6. Chama Edge Function passando:
 *    - aluno_id, conversation_id
 *    - tool_call_id_1, tool_call_id_2
 *    - macros_totais, dieta
 * 7. Encerra
 *
 * @input
 * - aluno_id: UUID
 * - mensagem_nutricionista: string
 *
 * @output
 * - success: boolean
 * - tool_calls_detectados: number
 * - conversation_id: string
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
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini";
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  const startedAt = new Date().toISOString();
  console.log(`[CRIAR-DIETA-COMPLETA] 🚀 Início: ${startedAt}`);
  try {
    const body = await req.json().catch(()=>({}));
    const { aluno_id, mensagem_nutricionista } = body;
    if (!aluno_id || !mensagem_nutricionista) {
      throw new Error("aluno_id e mensagem_nutricionista são obrigatórios");
    }
    console.log(`[1] ✅ Aluno: ${aluno_id}`);
    console.log(`[1] ✅ Mensagem: "${mensagem_nutricionista.substring(0, 50)}..."`);
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // ============================================
    // ETAPA 2: BUSCAR/CRIAR CONVERSATION_ID
    // ============================================
    console.log(`[2] 🔍 Buscando conversation_id...`);
    const { data: instrData, error: instrErr } = await supabase.from("instrucoes_nutricionista").select("id, conversation_id").eq("aluno_id", aluno_id).maybeSingle();
    if (instrErr) {
      throw new Error(`Erro ao buscar instruções: ${instrErr.message}`);
    }
    let conversation_id = instrData?.conversation_id || null;
    let instrucoes_id = instrData?.id || null;
    console.log(`[2] ${conversation_id ? '✅ Conversation: ' + conversation_id : '⚠️ Criando novo...'}`);
    if (!conversation_id) {
      console.log(`[2.1] 🆕 Criando conversation...`);
      const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          metadata: {
            tipo: 'criar_dieta',
            aluno_id: aluno_id
          }
        })
      });
      if (!createConvResponse.ok) {
        throw new Error(`Erro ao criar conversation: ${await createConvResponse.text()}`);
      }
      const convData = await createConvResponse.json();
      conversation_id = convData.id;
      console.log(`[2.1] ✅ Conversation criado: ${conversation_id}`);
      // Atualizar ou criar registro
      if (!instrucoes_id) {
        const { data: insertData, error: insertErr } = await supabase.from("instrucoes_nutricionista").insert({
          aluno_id: aluno_id,
          conversation_id: conversation_id,
          instrucoes_texto: "",
          instrucoes_ia: ""
        }).select("id").single();
        if (insertErr) {
          throw new Error(`Erro ao criar instrucoes_nutricionista: ${insertErr.message}`);
        }
        instrucoes_id = insertData.id;
        console.log(`[2.2] ✅ Registro criado: ${instrucoes_id}`);
      } else {
        await supabase.from("instrucoes_nutricionista").update({
          conversation_id: conversation_id
        }).eq("id", instrucoes_id);
        console.log(`[2.2] ✅ Conversation atualizado no registro`);
      }
    }
    // ============================================
    // ETAPA 3: BUSCAR PROMPT E TOOLS
    // ============================================
    console.log(`[3] 🔍 Buscando prompt: criar_dieta`);
    const { data: promptData, error: promptErr } = await supabase.from("prompts_sistema").select("prompt_base, functions_jsonb").eq("chave", "criar_dieta").maybeSingle();
    if (promptErr || !promptData) {
      throw new Error(`Prompt criar_dieta não encontrado: ${promptErr?.message}`);
    }
    console.log(`[3] ✅ Prompt: ${promptData.prompt_base.length} chars`);
    console.log(`[3] ✅ Tools: ${promptData.functions_jsonb.length} ferramenta(s)`);
    // ============================================
    // ETAPA 4: ENVIAR PARA OPENAI
    // ============================================
    console.log(`[4] 📤 Enviando para OpenAI...`);
    const payload = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      instructions: promptData.prompt_base,
      input: mensagem_nutricionista,
      tools: promptData.functions_jsonb
    };
    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    if (!openaiResponse.ok) {
      throw new Error(`Erro OpenAI: ${await openaiResponse.text()}`);
    }
    const responseData = await openaiResponse.json();
    console.log(`[4] ✅ Response ID: ${responseData.id}`);
    console.log(`[4] 📊 Input tokens: ${responseData.usage?.input_tokens ?? 'N/A'}`);
    console.log(`[4] 📊 Output tokens: ${responseData.usage?.output_tokens ?? 'N/A'}`);
    // ============================================
    // ETAPA 5: DETECTAR 2 TOOL CALLS
    // ============================================
    console.log(`[5] 🔍 Detectando tool calls...`);
    const toolCalls = [];
    for (const item of responseData.output || []){
      if (item.type === 'function_call') {
        toolCalls.push(item);
        console.log(`[5] 🔧 Tool detectada: ${item.name} (${item.call_id})`);
      }
    }
    if (toolCalls.length !== 2) {
      throw new Error(`Esperava 2 tool calls, recebeu ${toolCalls.length}`);
    }
    console.log(`[5] ✅ 2 tool calls detectados com sucesso`);
    // ============================================
    // ETAPA 6: EXTRAIR ARGUMENTOS
    // ============================================
    console.log(`[6] 📥 Extraindo argumentos...`);
    const tool1 = toolCalls[0];
    const tool2 = toolCalls[1];
    const args1 = JSON.parse(tool1.arguments || "{}");
    const args2 = JSON.parse(tool2.arguments || "{}");
    console.log(`[6] ✅ Tool 1 (${tool1.name}):`, Object.keys(args1));
    console.log(`[6] ✅ Tool 2 (${tool2.name}):`, Object.keys(args2));
    // Identificar qual é macros e qual é dieta pelo nome da tool
    let macros_totais, dieta, tool_call_id_macros, tool_call_id_dieta;
    if (tool1.name.includes('macro') || tool1.name.includes('calculo')) {
      macros_totais = args1;
      tool_call_id_macros = tool1.call_id;
      dieta = args2;
      tool_call_id_dieta = tool2.call_id;
    } else {
      macros_totais = args2;
      tool_call_id_macros = tool2.call_id;
      dieta = args1;
      tool_call_id_dieta = tool1.call_id;
    }
    console.log(`[6] ✅ Macros ID: ${tool_call_id_macros}`);
    console.log(`[6] ✅ Dieta ID: ${tool_call_id_dieta}`);
    // ============================================
    // ETAPA 7: CHAMAR EDGE FUNCTION
    // ============================================
    console.log(`[7] 🚀 Chamando processar-dieta-completa...`);
    const { error: edgeError } = await supabase.functions.invoke('processar-dieta-completa', {
      body: {
        aluno_id: aluno_id,
        conversation_id: conversation_id,
        tool_call_id_macros: tool_call_id_macros,
        tool_call_id_dieta: tool_call_id_dieta,
        macros_totais: macros_totais,
        dieta: dieta
      }
    });
    if (edgeError) {
      console.error(`[7] ❌ Erro na Edge Function:`, edgeError);
      throw new Error(`Erro ao processar dieta: ${edgeError.message}`);
    }
    console.log(`[7] ✅ Edge Function executada com sucesso`);
    // ============================================
    // ETAPA 8: RETORNAR SUCESSO
    // ============================================
    const finishedAt = new Date().toISOString();
    console.log(`[8] 🎉 Concluído: ${finishedAt}\n`);
    return jsonResponse({
      success: true,
      tool_calls_detectados: 2,
      conversation_id: conversation_id,
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
