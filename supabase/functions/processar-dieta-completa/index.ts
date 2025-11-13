/**
 * @name processar-dieta-completa
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-09
 * @lastModified 2025-11-09T09:30:00-03:00
 *
 * @description
 * Processa dieta completa: insere em diet_plans e finaliza 2 tool calls.
 *
 * @workflow
 * 1. Recebe macros_totais e dieta
 * 2. Desativa planos anteriores
 * 3. Insere novo plano em diet_plans:
 *    - meta_diaria_geral = macros_totais
 *    - plano_semanal = dieta
 * 4. Finaliza tool_call_macros
 * 5. Finaliza tool_call_dieta
 * 6. Obtém resposta contextual da IA
 * 7. Envia ao usuário
 * 8. Retorna sucesso
 *
 * @input
 * - aluno_id: UUID
 * - conversation_id: string
 * - tool_call_id_macros: string
 * - tool_call_id_dieta: string
 * - macros_totais: object
 * - dieta: object
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type"
};
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
  console.log(`[PROCESSAR-DIETA] 🚀 Início`);
  try {
    const { aluno_id, conversation_id, tool_call_id_macros, tool_call_id_dieta, macros_totais, dieta } = await req.json();
    if (!aluno_id || !conversation_id || !tool_call_id_macros || !tool_call_id_dieta) {
      throw new Error("Parâmetros obrigatórios faltando");
    }
    console.log(`[1] ✅ Aluno: ${aluno_id}`);
    console.log(`[1] ✅ Conversation: ${conversation_id}`);
    console.log(`[1] ✅ Tool Call Macros: ${tool_call_id_macros}`);
    console.log(`[1] ✅ Tool Call Dieta: ${tool_call_id_dieta}`);
    const supabase = createClient(Deno.env.get("SUPABASE_URL"), Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
    // ============================================
    // ETAPA 2: DESATIVAR PLANOS ANTERIORES
    // ============================================
    console.log(`[2] 🔄 Desativando planos anteriores...`);
    await supabase.from("diet_plans").update({
      is_active: false
    }).eq("aluno_id", aluno_id);
    console.log(`[2] ✅ Planos anteriores desativados`);
    // ============================================
    // ETAPA 3: INSERIR NOVO PLANO
    // ============================================
    console.log(`[3] 💾 Inserindo novo plano...`);
    console.log(`[3] 📊 Meta diária:`, macros_totais);
    console.log(`[3] 📋 Plano semanal: ${JSON.stringify(dieta).length} chars`);
    const { data: insertData, error: insertErr } = await supabase.from("diet_plans").insert({
      aluno_id: aluno_id,
      version: 1,
      is_active: true,
      meta_diaria_geral: macros_totais,
      plano_semanal: dieta,
      data_inicio: new Date().toISOString().split('T')[0]
    }).select("id").single();
    if (insertErr) {
      console.error(`[3] ❌ Erro ao inserir:`, insertErr);
      throw new Error(`Erro ao criar plano: ${insertErr.message}`);
    }
    console.log(`[3] ✅ Plano criado: ${insertData.id}`);
    // ============================================
    // ETAPA 4: FINALIZAR TOOL CALL MACROS
    // ============================================
    console.log(`[4] 🔄 Finalizando tool call: macros...`);
    const payloadMacros = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      tool_choice: "none",
      input: [
        {
          type: "function_call_output",
          call_id: tool_call_id_macros,
          output: JSON.stringify({
            status: "Sucesso",
            message: "Macros calculados e salvos"
          })
        }
      ]
    };
    const responseMacros = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payloadMacros)
    });
    if (!responseMacros.ok) {
      throw new Error(`Erro ao finalizar macros: ${await responseMacros.text()}`);
    }
    console.log(`[4] ✅ Tool call macros finalizado`);
    // ============================================
    // ETAPA 5: FINALIZAR TOOL CALL DIETA
    // ============================================
    console.log(`[5] 🔄 Finalizando tool call: dieta...`);
    const payloadDieta = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      tool_choice: "none",
      input: [
        {
          type: "function_call_output",
          call_id: tool_call_id_dieta,
          output: JSON.stringify({
            status: "Sucesso",
            message: "Plano alimentar criado com sucesso"
          })
        }
      ]
    };
    const responseDieta = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payloadDieta)
    });
    if (!responseDieta.ok) {
      throw new Error(`Erro ao finalizar dieta: ${await responseDieta.text()}`);
    }
    const dietaData = await responseDieta.json();
    console.log(`[5] ✅ Tool call dieta finalizado`);
    console.log(`[5] 📊 Response ID: ${dietaData.id}`);
    // ============================================
    // ETAPA 6: EXTRAIR RESPOSTA DA IA
    // ============================================
    console.log(`[6] 💬 Extraindo resposta da IA...`);
    let respostaIA = '';
    for (const item of dietaData.output || []){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) {
      respostaIA = '✅ Plano alimentar criado com sucesso! O plano está pronto e disponível para o aluno.';
      console.warn(`[6] ⚠️ Resposta vazia, usando mensagem padrão`);
    }
    console.log(`[6] ✅ Resposta (${respostaIA.length} chars): "${respostaIA.substring(0, 100)}..."`);
    // ============================================
    // ETAPA 7: ENVIAR AO NUTRICIONISTA
    // ============================================
    console.log(`[7] 📤 Enviando resposta...`);
    // Salvar em instrucoes_nutricionista
    await supabase.from("instrucoes_nutricionista").update({
      instrucoes_texto: respostaIA,
      updated_at: new Date().toISOString()
    }).eq("aluno_id", aluno_id);
    console.log(`[7] ✅ Resposta salva em instrucoes_nutricionista`);
    // ============================================
    // ETAPA 8: RETORNAR SUCESSO
    // ============================================
    console.log(`[8] 🎉 Processo concluído com sucesso\n`);
    return jsonResponse({
      success: true,
      diet_plan_id: insertData.id,
      resposta_ia: respostaIA,
      message: "Plano alimentar criado e tool calls finalizados"
    });
  } catch (error) {
    console.error(`[ERRO] ${error.message}`);
    return jsonResponse({
      error: error.message
    }, 500);
  }
});
