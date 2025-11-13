/**
 * @name chat-personal
 * @version 1.0.0
 * @author PersonalCoach AI Development Team
 * @date 2025-11-09
 * @lastModified 2025-11-09T08:00:00-03:00
 *
 * @description
 * Edge Function conversacional para o personal trainer discutir plano de treino com a IA.
 * Não possui tool calls - apenas conversa natural.
 *
 * @workflow
 * 1. Recebe: { aluno_id, mensagem_personal }
 * 2. Busca conversation_id existente em instrucoes_personal
 * 3. Se não existe: cria nova conversation + monta prompt com variáveis do aluno
 * 4. Se existe: continua conversation existente
 * 5. Envia mensagem do personal para OpenAI
 * 6. Salva resposta da IA em instrucoes_da_ia_personal
 * 7. Retorna resposta para o personal trainer
 *
 * @input
 * - aluno_id: UUID
 * - mensagem_personal: string
 *
 * @output
 * - resposta_ia: string
 * - conversation_id: string
 * - is_new_conversation: boolean
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
serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  const startedAt = new Date().toISOString();
  console.log(`[CHAT-PERSONAL] 🚀 Início: ${startedAt}`);
  try {
    const body = await req.json().catch(()=>({}));
    const { aluno_id, mensagem_personal } = body;
    if (!aluno_id || !mensagem_personal) {
      throw new Error("aluno_id e mensagem_personal são obrigatórios");
    }
    console.log(`[1] ✅ Aluno: ${aluno_id}`);
    console.log(`[1] ✅ Mensagem (${mensagem_personal.length} chars): "${mensagem_personal.substring(0, 50)}..."`);
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // ============================================
    // ETAPA 2: BUSCAR CONVERSATION_ID EXISTENTE
    // ============================================
    console.log(`[2] 🔍 Buscando conversation_id existente...`);
    const { data: instrData, error: instrErr } = await supabase.from("instrucoes_personal").select("id, conversation_id, instrucoes_texto").eq("aluno_id", aluno_id).maybeSingle();
    if (instrErr) {
      throw new Error(`Erro ao buscar instruções: ${instrErr.message}`);
    }
    let conversation_id = instrData?.conversation_id || null;
    let instrucoes_id = instrData?.id || null;
    let is_new_conversation = false;
    console.log(`[2] ${conversation_id ? '✅ Conversation existente: ' + conversation_id : '⚠️ Nenhuma conversation encontrada'}`);
    // ============================================
    // ETAPA 3: SE NÃO EXISTE, CRIAR NOVA
    // ============================================
    if (!conversation_id) {
      console.log(`[3] 🆕 Criando nova conversation...`);
      // 3.1: Buscar prompt base
      const { data: promptData, error: promptErr } = await supabase.from("prompts_sistema").select("prompt_base").eq("chave", "prompt_personal").maybeSingle();
      if (promptErr || !promptData) {
        throw new Error(`Prompt prompt_personal não encontrado: ${promptErr?.message}`);
      }
      console.log(`[3.1] ✅ Prompt base encontrado (${promptData.prompt_base.length} chars)`);
      // 3.2: Buscar dados do aluno
      const { data: alunoData, error: alunoErr } = await supabase.from("alunos").select("nome_completo").eq("id", aluno_id).single();
      if (alunoErr) {
        throw new Error(`Aluno não encontrado: ${alunoErr.message}`);
      }
      console.log(`[3.2] ✅ Nome do aluno: ${alunoData.nome_completo}`);
      // 3.3: Buscar dynamic_prompts
      const { data: dynamicData, error: dynamicErr } = await supabase.from("dynamic_prompts").select("saude_e_rotina_json").eq("aluno_id", aluno_id).single();
      if (dynamicErr) {
        throw new Error(`Dynamic prompts não encontrado: ${dynamicErr.message}`);
      }
      console.log(`[3.3] ✅ Saúde e rotina carregado`);
      // 3.4: Buscar preferencias_treino (prioridade para o personal)
      const { data: prefTreinoData, error: prefTreinoErr } = await supabase.from("preferencias_treino").select("local_treino, equipamentos_disponiveis, experiencia_treino, dias_preferenciais_treino, horarios_preferenciais_treino").eq("aluno_id", aluno_id).maybeSingle();
      console.log(`[3.4] ✅ Preferências de treino carregadas`);
      // 3.5: Buscar goals
      const { data: goalsData, error: goalsErr } = await supabase.from("goals").select("nome_meta, metrica_primaria, valor_meta, motivacao_principal, data_inicio, data_fim, valor_inicial").eq("aluno_id", aluno_id).eq("status", "ativo").maybeSingle();
      console.log(`[3.5] ✅ Metas carregadas:`, goalsData);
      // 3.6: Buscar preferencias_alimentares (se relevante para contexto)
      const { data: prefAlimData, error: prefAlimErr } = await supabase.from("preferencias_alimentares").select("restricoes_alimentares, alimentos_nao_gosta, alimentos_favoritos").eq("aluno_id", aluno_id).maybeSingle();
      console.log(`[3.6] ✅ Preferências alimentares carregadas`);
      // 3.7: Substituir variáveis no prompt
      console.log(`[3.7] 🔄 Substituindo variáveis no prompt...`);
      let prompt_final = promptData.prompt_base;
      console.log(`[3.7.1] 📝 {nome_aluno}: "${alunoData.nome_completo}"`);
      prompt_final = prompt_final.replace(/\{nome_aluno\}/g, alunoData.nome_completo);
      const saudeJson = JSON.stringify(dynamicData.saude_e_rotina_json || {}, null, 2);
      console.log(`[3.7.2] 📝 {{saude_e_rotina_json}} (${saudeJson.length} chars): ${saudeJson.substring(0, 100)}...`);
      prompt_final = prompt_final.replace(/\{\{saude_e_rotina_json\}\}/g, saudeJson);
      const prefTreinoJson = JSON.stringify(prefTreinoData || {}, null, 2);
      console.log(`[3.7.3] 📝 {{preferencias_treino}} (${prefTreinoJson.length} chars): ${prefTreinoJson.substring(0, 100)}...`);
      prompt_final = prompt_final.replace(/\{\{preferencias_treino\}\}/g, prefTreinoJson);
      const metasJson = JSON.stringify(goalsData || {}, null, 2);
      console.log(`[3.7.4] 📝 {{metas}} (${metasJson.length} chars): ${metasJson.substring(0, 100)}...`);
      prompt_final = prompt_final.replace(/\{\{metas\}\}/g, metasJson);
      const prefAlimJson = JSON.stringify(prefAlimData || {}, null, 2);
      console.log(`[3.7.5] 📝 {{preferencias_alimentares}} (${prefAlimJson.length} chars): ${prefAlimJson.substring(0, 100)}...`);
      prompt_final = prompt_final.replace(/\{\{preferencias_alimentares\}\}/g, prefAlimJson);
      console.log(`[3.7] ✅ Variáveis substituídas. Prompt final: ${prompt_final.length} chars`);
      // 3.8: Criar conversation na OpenAI
      const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          metadata: {
            tipo: 'chat_personal',
            aluno_id: aluno_id
          }
        })
      });
      if (!createConvResponse.ok) {
        throw new Error(`Erro ao criar conversation: ${await createConvResponse.text()}`);
      }
      const convData = await createConvResponse.json();
      conversation_id = convData.id;
      is_new_conversation = true;
      console.log(`[3.8] ✅ Conversation criado: ${conversation_id}`);
      // 3.9: Enviar mensagem inicial (system prompt)
      const initialPayload = {
        model: OPENAI_MODEL,
        conversation: conversation_id,
        store: true,
        input: [
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
        ]
      };
      const initialResponse = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(initialPayload)
      });
      if (!initialResponse.ok) {
        throw new Error(`Erro ao inicializar conversation: ${await initialResponse.text()}`);
      }
      console.log(`[3.9] ✅ System prompt enviado`);
      // 3.10: Criar ou atualizar registro em instrucoes_personal
      if (!instrucoes_id) {
        const { data: insertData, error: insertErr } = await supabase.from("instrucoes_personal").insert({
          aluno_id: aluno_id,
          conversation_id: conversation_id,
          instrucoes_texto: "",
          instrucoes_da_ia: ""
        }).select("id").single();
        if (insertErr) {
          throw new Error(`Erro ao criar instrucoes_personal: ${insertErr.message}`);
        }
        instrucoes_id = insertData.id;
        console.log(`[3.10] ✅ Registro criado: ${instrucoes_id}`);
      } else {
        await supabase.from("instrucoes_personal").update({
          conversation_id: conversation_id
        }).eq("id", instrucoes_id);
        console.log(`[3.10] ✅ Conversation ID atualizado no registro`);
      }
    }
    // ============================================
    // ETAPA 4: ENVIAR MENSAGEM DO PERSONAL
    // ============================================
    console.log(`[4] 📤 Enviando mensagem do personal...`);
    const messagePayload = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      input: mensagem_personal
    };
    const messageResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(messagePayload)
    });
    if (!messageResponse.ok) {
      throw new Error(`Erro OpenAI: ${await messageResponse.text()}`);
    }
    const responseData = await messageResponse.json();
    console.log(`[4] ✅ Response ID: ${responseData.id}`);
    console.log(`[4] 📊 Input tokens: ${responseData.usage?.input_tokens ?? 'N/A'}`);
    console.log(`[4] 📊 Output tokens: ${responseData.usage?.output_tokens ?? 'N/A'}`);
    // ============================================
    // ETAPA 5: EXTRAIR RESPOSTA DA IA
    // ============================================
    let resposta_ia = "";
    for (const item of responseData.output || []){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          resposta_ia = textContent.text;
          break;
        }
      }
    }
    if (!resposta_ia) {
      throw new Error("Resposta vazia da IA");
    }
    console.log(`[5] ✅ Resposta (${resposta_ia.length} chars): "${resposta_ia.substring(0, 100)}..."`);
    // ============================================
    // ETAPA 6: SALVAR RESPOSTA NO BANCO
    // ============================================
    console.log(`[6] 💾 Salvando resposta...`);
    console.log(`[6] 🆔 Aluno ID: ${aluno_id}`);
    console.log(`[6] 📝 Resposta (${resposta_ia.length} chars): "${resposta_ia.substring(0, 200)}..."`);
    const { data: updateData, error: updateErr } = await supabase.from("instrucoes_personal").update({
      instrucoes_da_ia: resposta_ia,
      updated_at: new Date().toISOString()
    }).eq("aluno_id", aluno_id).select();
    if (updateErr) {
      console.error(`[6] ❌ Erro no UPDATE: ${updateErr.message}`);
      throw new Error(`Erro ao salvar resposta: ${updateErr.message}`);
    }
    console.log(`[6] ✅ Registros atualizados: ${updateData?.length ?? 0}`);
    if (updateData && updateData.length > 0) {
      console.log(`[6] ✅ Resposta salva em instrucoes_da_ia`);
    } else {
      console.warn(`[6] ⚠️ Nenhum registro foi atualizado! Aluno ID: ${aluno_id}`);
    }
    // ============================================
    // ETAPA 7: RETORNAR RESPOSTA
    // ============================================
    const finishedAt = new Date().toISOString();
    console.log(`[7] 🎉 Concluído: ${finishedAt}\n`);
    return jsonResponse({
      success: true,
      resposta_ia: resposta_ia,
      conversation_id: conversation_id,
      is_new_conversation: is_new_conversation,
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
