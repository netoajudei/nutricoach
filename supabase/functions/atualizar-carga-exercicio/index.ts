/**
 * @name atualizar-carga-exercicio
 * @version 2.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-07
 *
 * @changelog
 * - v2.0.0:
 * - Implementado o "Super-Catch" de segurança (padrão v1.4.0).
 * - O 'catch' principal agora finaliza o tool call em caso de
 * QUALQUER erro (ex: falha na RPC), desbloqueando a conversa.
 * - ADICIONADO: O payload de erro no 'catch' inclui a
 * 'instrucao_para_llm' para autocorreção.
 * - Lógica de validação e RPC agora usa 'throw new Error()'
 * para ser capturada pelo 'catch' principal.
 * - Adicionado cabeçalho de comentários.
 *
 * @description
 * Edge Function (Ação 2) chamada pelo webhook-wame para finalizar
 * uma proposta de atualização de carga.
 *
 * @workflow
 * 1. Recebe 'botao_id' e 'confirmado' (true/false) do webhook-wame.
 * 2. Busca 'botoes_ativos' para obter todos os IDs de conversa e argumentos.
 * 3. Tenta processar a lógica:
 * - Se 'confirmado: false', finaliza o tool call com "Cancelado".
 * - Se 'confirmado: true', chama a RPC 'atualizar_carga_exercicio' para
 * salvar no banco e finaliza o tool call com "Sucesso".
 * 4. Se FALHAR (em qualquer etapa do 'true'):
 * - O 'catch' principal assume.
 * - Chama 'finishOpenAI' com uma mensagem de erro genérica E
 * a 'instrucao_para_llm'.
 * - Limpa os bloqueios.
 * - Retorna 500 (mas a conversa do usuário já foi desbloqueada).
 *
 * @param {string} botao_id - ID do registro em 'botoes_ativos'.
 * @param {boolean} confirmado - Se o usuário clicou 'Sim' ou 'Não'.
 */ // Edge Function: atualizar-carga-via-botao (com encerramento de conversation OpenAI)
// Entrada: { botao_id: string, confirmado: boolean }
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4o-mini"; // Alinhado
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
serve(async (req)=>{
  if (req.method === "OPTIONS") return new Response("ok", {
    headers: corsHeaders
  });
  const startedAt = new Date().toISOString();
  // ⬇️⬇️⬇️ VARIÁVEIS DE LIMPEZA (MOVIDAS PARA CÁ) ⬇️⬇️⬇️
  let botao_id = null;
  let aluno_id = null;
  let conversation_id = null;
  let tool_call_id = null;
  // ⬆️⬆️⬆️ FIM DA ALTERAÇÃO ⬆️⬆️⬆️
  try {
    const body = await req.json().catch(()=>({}));
    botao_id = body?.botao_id; // Atribui ao escopo externo
    const confirmado = body?.confirmado;
    console.log("[ATUALIZAR-CARGA] ▶️ Start", {
      startedAt,
      botao_id,
      confirmado
    });
    if (!SUPABASE_URL || !SERVICE_ROLE) {
      throw new Error("Env Supabase ausente"); // Lança erro para o Super-Catch
    }
    if (!botao_id || typeof confirmado !== "boolean") {
      throw new Error("Envie { botao_id: string, confirmado: boolean }"); // Lança erro
    }
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // 1) Buscar o botão primeiro
    const { data: botao, error: btnErr } = await supabase.from("botoes_ativos").select("id, aluno_id, argumentos, conversation_id, tool_call_id, tipo_acao").eq("id", botao_id).maybeSingle();
    console.log("[ATUALIZAR-CARGA] 🔎 Botão", {
      found: !!botao,
      btnErr
    });
    if (btnErr) throw new Error(`Falha ao buscar botão: ${btnErr.message}`);
    if (!botao) {
      // Se o botão não for encontrado, já foi processado. Retorna 200 OK.
      return j({
        success: true,
        message: "Botão não encontrado (provavelmente já processado)."
      }, 200);
    }
    // ⬇️⬇️⬇️ Atribui dados de limpeza ao escopo externo ⬇️⬇️⬇️
    aluno_id = botao.aluno_id;
    conversation_id = botao.conversation_id ?? null;
    tool_call_id = botao.tool_call_id ?? null;
    // ⬆️⬆️⬆️ FIM DA ALTERAÇÃO ⬆️⬆️⬆️
    const args = botao.argumentos ?? {};
    const whatsapp = args["whatsapp"];
    const nome_exercicio = args["nome_exercicio"];
    const carga_atual = args["carga_atual"];
    const nova_carga_raw = args["nova_carga"];
    const nova_carga = typeof nova_carga_raw === "number" ? nova_carga_raw : parseFloat(String(nova_carga_raw ?? ""));
    const exercicio_id = args["exercicio_id"];
    // === Ramo de CANCELAMENTO (confirmado=false) ===
    // (Esta parte já é segura e finaliza a conversa, então mantemos)
    if (!confirmado) {
      console.log("[ATUALIZAR-CARGA] 🟡 Cancelado pelo usuário");
      const okFinish = await finishOpenAIWithFunctionOutput({
        conversation_id,
        tool_call_id,
        status: "Cancelado",
        message: "Usuário cancelou a operação. Nenhuma alteração foi feita."
      });
      const respostaIA = okFinish.outputText || "Ok! 👍 Operação cancelada. Se precisar de algo, é só me avisar!";
      await sendMensagemWhatsapp(supabase, aluno_id, respostaIA);
      await supabase.from("botoes_ativos").delete().eq("id", botao_id);
      await supabase.from("alunos").update({
        aguardando_confirmacao: null
      }).eq("id", aluno_id);
      return j({
        success: true,
        action: "cancelado",
        resposta_enviada: respostaIA
      });
    }
    // === Ramo de CONFIRMAÇÃO (confirmado=true) ===
    // (Modificado para usar o Super-Catch)
    // ⬇️⬇️⬇️ Validações agora lançam Erro ⬇️⬇️⬇️
    if (!exercicio_id || !aluno_id) throw new Error("exercicio_id/aluno_id ausentes nos argumentos do botão");
    if (!isFinite(nova_carga)) throw new Error(`nova_carga inválida/ausente: ${nova_carga_raw}`);
    // ⬆️⬆️⬆️ FIM DA ALTERAÇÃO ⬆️⬆️⬆️
    console.log("[ATUALIZAR-CARGA] 🛠️ RPC atualizar_carga_exercicio →", {
      p_exercicio_id: exercicio_id,
      p_aluno_id: aluno_id,
      p_nova_carga: nova_carga,
      p_whatsapp: whatsapp ?? null
    });
    const { data: rpcData, error: rpcErr } = await supabase.rpc("atualizar_carga_exercicio", {
      p_exercicio_id: exercicio_id,
      p_aluno_id: aluno_id,
      p_nova_carga: nova_carga,
      p_whatsapp: whatsapp ?? null
    });
    // ⬇️⬇️⬇️ Erro de RPC agora lança Erro ⬇️⬇️⬇️
    if (rpcErr) {
      console.error("[ATUALIZAR-CARGA] 💥 Erro na RPC", rpcErr);
      throw new Error(`Falha na RPC atualizar_carga_exercicio: ${rpcErr.message}`);
    }
    // ⬆️⬆️⬆️ FIM DA ALTERAÇÃO ⬆️⬆️⬆️
    console.log("[ATUALIZAR-CARGA] 📥 RPC retorno OK", {
      rpcData
    });
    // 1) Finaliza a tool call na OpenAI (Caminho Feliz)
    const okFinish = await finishOpenAIWithFunctionOutput({
      conversation_id,
      tool_call_id,
      status: "OK",
      message: "Carga atualizada com sucesso.",
      extra: {
        exercicio: nome_exercicio ?? null,
        carga_anterior: carga_atual ?? null,
        carga_nova: nova_carga
      }
    });
    // 2) Mensagem de confirmação pro aluno (Caminho Feliz)
    const resumoHumano = nome_exercicio ? `Perfeito! Atualizei a carga de *${nome_exercicio}* para **${nova_carga}kg**.` : `Perfeito! Atualizei a carga para **${nova_carga}kg**.`;
    const reply = okFinish.outputText || `${resumoHumano} Quer ajustar mais algum exercício? 💪`;
    await sendMensagemWhatsapp(supabase, aluno_id, reply);
    // 3) Deleta botão e limpa bloqueio (Caminho Feliz)
    await supabase.from("botoes_ativos").delete().eq("id", botao_id);
    await supabase.from("alunos").update({
      aguardando_confirmacao: null
    }).eq("id", aluno_id);
    return j({
      success: true,
      action: "confirmado",
      message: "Carga atualizada e conversation finalizada",
      resultado: rpcData,
      startedAt,
      finishedAt: new Date().toISOString()
    });
  } catch (e) {
    // ========================================
    // ⬇️⬇️⬇️ "SUPER-CATCH" (v2.0.0) ⬇️⬇️⬇️
    // ========================================
    console.error("[ATUALIZAR-CARGA] 💥 Erro inesperado (Super-Catch)", e);
    // Re-inicializa o supabase para garantir que esteja disponível
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    // 1. Tenta finalizar a conversa MESMO EM CASO DE ERRO
    if (conversation_id && tool_call_id && aluno_id) {
      console.warn("[ATUALIZAR-CARGA] ⚠️ Tentando finalizar tool call para desbloquear conversa...");
      // ⬇️⬇️⬇️ INSTRUÇÃO PARA A LLM (COMO SOLICITADO) ⬇️⬇️⬇️
      const outputErro = {
        status: "Erro",
        message: `Houve um erro (Detalhe: ${e.message}). Informe ao usuário que não foi possível ATUALIZAR A CARGA e que ele pode tentar novamente.`,
        instrucao_para_llm: "Os dados de input da tool (exercicio_id, nova_carga) não correspondem com os esperados pelo back end. Por favor, analise novamente o prompt E se o usuário Repetir a operação traga as informações corretas."
      };
      // ⬆️⬆️⬆️ FIM DA ALTERAÇÃO ⬆️⬆️⬆️
      const okFinish = await finishOpenAIWithFunctionOutput({
        conversation_id: conversation_id,
        tool_call_id: tool_call_id,
        status: outputErro.status,
        message: outputErro.message,
        extra: {
          instrucao_para_llm: outputErro.instrucao_para_llm
        }
      });
      const respostaIA = okFinish.outputText || "Desculpe, tive um problema ao tentar registrar sua carga. Por favor, tente novamente.";
      await sendMensagemWhatsapp(supabase, aluno_id, respostaIA);
      console.warn("[ATUALIZAR-CARGA] ⚠️ Tool call de erro finalizado.");
    } else {
      console.error("[ATUALIZAR-CARGA] ❌ Erro crítico ANTES de carregar dados do botão. Não é possível finalizar tool call.");
    }
    // 2. Tenta limpar os bloqueios do DB MESMO EM CASO DE ERRO
    try {
      console.warn("[ATUALIZAR-CARGA] ⚠️ Tentando limpar bloqueios após erro...");
      if (botao_id) {
        await supabase.from("botoes_ativos").delete().eq("id", botao_id);
      }
      if (aluno_id) {
        await supabase.from("alunos").update({
          aguardando_confirmacao: null
        }).eq("id", aluno_id);
      }
      console.warn("[ATUALIZAR-CARGA] ⚠️ Bloqueios limpos.");
    } catch (cleanErr) {
      console.error("[ATUALIZAR-CARGA] ❌ Falha ao limpar bloqueios:", cleanErr);
    }
    // 3. Retorna o erro 500 para o log
    return j({
      error: String(e?.message ?? e)
    }, 500);
  // ⬆️⬆️⬆️ FIM DO SUPER-CATCH ⬆️⬆️⬆️
  }
});
// ========================================
// FUNÇÕES HELPER (Originais do seu arquivo, não modificadas)
// ========================================
function j(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
/** Encerra a tool call com o mesmo formato do `cancelar-registro` e retorna também o texto do assistant (se houver). */ async function finishOpenAIWithFunctionOutput(params) {
  try {
    if (!OPENAI_API_KEY || !params.conversation_id || !params.tool_call_id) {
      console.warn("[ATUALIZAR-CARGA] ℹ️ finishOpenAI: params faltando", {
        hasKey: !!OPENAI_API_KEY,
        conversation_id: params.conversation_id,
        tool_call_id: params.tool_call_id
      });
      return {
        ok: false
      };
    }
    // ⬇️⬇️⬇️ Payload de finalização (usado pelo seu helper) ⬇️⬇️⬇️
    const payload = {
      model: OPENAI_MODEL,
      conversation: params.conversation_id,
      store: true,
      tool_choice: "none",
      input: [
        {
          type: "function_call_output",
          call_id: params.tool_call_id,
          output: JSON.stringify({
            status: params.status,
            message: params.message,
            ...params.extra ? {
              extra: params.extra
            } : {}
          })
        }
      ]
    };
    // ⬆️⬆️⬆️ FIM DO PAYLOAD ⬆️⬆️⬆️
    const res = await fetch("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${OPENAI_API_KEY}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify(payload)
    });
    if (!res.ok) {
      const txt = await res.text();
      console.warn("[ATUALIZAR-CARGA] ⚠️ finishOpenAI HTTP != 200:", txt);
      return {
        ok: false
      };
    }
    const data = await res.json().catch(()=>({}));
    // extrai a mensagem do assistant
    let outputText;
    for (const item of data.output || []){
      if (item.type === "message" && item.role === "assistant") {
        const textContent = item.content?.find((c)=>c.type === "output_text");
        if (textContent?.text) {
          outputText = textContent.text;
          break;
        }
      }
    }
    console.log("[ATUALIZAR-CARGA] 🟢 finishOpenAI OK", {
      id: data?.id,
      hasOutputText: !!outputText
    });
    return {
      ok: true,
      outputText
    };
  } catch (e) {
    console.warn("[ATUALIZAR-CARGA] ⚠️ finishOpenAI exceção:", e);
    return {
      ok: false
    };
  }
}
/** Usa tua edge `enviar_menssagem_whatsapp` para entregar texto ao aluno */ async function sendMensagemWhatsapp(supabase, aluno_id, mensagem) {
  try {
    await supabase.functions.invoke("enviar_menssagem_whatsapp", {
      body: {
        aluno_id,
        mensagem
      }
    });
  } catch (e) {
    console.warn("[ATUALIZAR-CARGA] ⚠️ WhatsApp invoke falhou:", e);
  }
}
