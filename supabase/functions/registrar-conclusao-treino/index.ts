/**
 * @name registrar-conclusao-treino
 * @version 1.1.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-07
 *
 * @changelog
 * - v1.1.0:
 * - Implementado o "Super-Catch" de segurança (v1.4.0 do padrão).
 * - O 'catch' principal agora finaliza o tool call em caso de
 * QUALQUER erro (validação, RPC, etc.), desbloqueando a conversa.
 * - ADICIONADO: O payload de erro no 'catch' agora inclui a
 * 'instrucao_para_llm' para ajudar o modelo a se autocorrigir.
 * - Lógica de validação (gateways) agora usa 'throw new Error()'
 * para ser capturada pelo 'catch' principal.
 *
 * @description
 * 1. Recebe 'botao_id' e 'confirmado'.
 * 2. Busca 'botoes_ativos' para obter todos os IDs de conversa.
 * 3. Tenta processar a lógica (validar e chamar RPC).
 * 4. Se FALHAR (em qualquer etapa):
 * - O 'catch' principal assume.
 * - Chama 'finalizarToolCall' com uma mensagem de erro genérica E
 * a 'instrucao_para_llm'.
 * - Limpa os bloqueios.
 * - Retorna 500 (mas a conversa do usuário já foi desbloqueada).
 * 5. Se TIVER SUCESSO:
 * - Chama 'finalizarToolCall' com a mensagem de sucesso.
 * - Limpa os bloqueios e retorna 200.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') || 'gpt-4o-mini';
// ========================================
// HELPER: Finalizar Tool Call (Padrão v1.2)
// (Não modificado)
// ========================================
async function finalizarToolCallEChamarWhatsApp(supabase, conversation_id, tool_call_id, outputJsonString, aluno_id) {
  let respostaIA = '';
  try {
    const openaiPayload = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      tool_choice: "none",
      input: [
        {
          type: "function_call_output",
          call_id: tool_call_id,
          output: outputJsonString
        }
      ]
    };
    console.log(`[finalizarToolCall] 🤖 Enviando para OpenAI... (Tool: ${tool_call_id})`);
    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(openaiPayload)
    });
    if (!openaiResponse.ok) {
      const errorText = await openaiResponse.text();
      console.error(`[finalizarToolCall] ❌ Erro OpenAI: ${errorText}`);
      throw new Error(`Erro OpenAI: ${errorText}`);
    }
    const openaiData = await openaiResponse.json();
    console.log(`[finalizarToolCall] ✅ OpenAI respondeu. (Response ID: ${openaiData.id})`);
    // Extrair a resposta textual da IA
    for (const item of openaiData.output || []){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    // Fallback
    if (!respostaIA) {
      console.warn('[finalizarToolCall] ⚠️ Resposta vazia da IA, usando fallback.');
      const outputParsed = JSON.parse(outputJsonString);
      // Se a msg de erro da IA falhar, manda a msg de erro do output
      if (outputParsed.status !== "Sucesso") {
        respostaIA = outputParsed.message;
      } else {
        respostaIA = "Ok, treino registrado!";
      }
    }
    console.log(`[finalizarToolCall] 💬 Resposta da IA: ${respostaIA.substring(0, 100)}`);
    // Enviar a resposta da IA para o usuário
    console.log(`[finalizarToolCall] 📱 Enviando mensagem para o usuário...`);
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
  } catch (err) {
    console.error(`[finalizarToolCall] ❌ Erro no processo de finalização:`, err.message);
  }
  return respostaIA;
}
// ========================================
// FUNÇÃO PRINCIPAL
// ========================================
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  // ⬇️⬇️⬇️ VARIÁVEIS DE LIMPEZA (MOVIDAS PARA CÁ) ⬇️⬇️⬇️
  let botao_id = null;
  let aluno_id_para_limpeza = null;
  let conversation_id_para_limpeza = null;
  let tool_call_id_para_limpeza = null;
  try {
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Receber payload do Webhook-WAME
    const body = await req.json();
    botao_id = body.botao_id;
    const { confirmado } = body;
    if (!botao_id) {
      throw new Error('Payload incompleto. "botao_id" é obrigatório.');
    }
    console.log(`[registrar-conclusao-treino] 🚀 Processando botão: ${botao_id} | Confirmado: ${confirmado}`);
    // 2. Buscar dados do botão ativo
    const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('aluno_id, conversation_id, tool_call_id, argumentos').eq('id', botao_id).single();
    if (botaoErr || !botao) {
      console.warn(`[registrar-conclusao-treino] ⚠️ Botão ${botao_id} não encontrado. Pode já ter sido processado.`);
      return new Response(JSON.stringify({
        success: true,
        message: "Botão já processado."
      }), {
        status: 200,
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        }
      });
    }
    // ⬇️⬇️⬇️ Armazena dados de limpeza IMEDIATAMENTE ⬇️⬇️⬇️
    const { aluno_id, conversation_id, tool_call_id, argumentos: args } = botao;
    aluno_id_para_limpeza = aluno_id;
    conversation_id_para_limpeza = conversation_id;
    tool_call_id_para_limpeza = tool_call_id;
    // ⬆️⬆️⬆️ Fim da alteração ⬆️⬆️⬆️
    let outputJsonString = "";
    let mensagemEnviada = "";
    // 3. Lógica de Confirmação (Bifurcação)
    if (confirmado === true) {
      // ========================================
      // AÇÃO: Confirmar (Sim)
      // ========================================
      console.log(`[registrar-conclusao-treino] ✅ Confirmado. Validando e registrando...`);
      const { nome_treino, duracao, observacoes } = args;
      // 3a. Gateways (Validação de dados)
      if (!nome_treino || !observacoes) {
        throw new Error("Dados incorretos. O nome do treino e as observações são obrigatórios.");
      }
      if (duracao <= 0 || duracao > 300) {
        throw new Error(`A duração do treino informada (${duracao} min) parece inválida.`);
      }
      // 3b. Validação e Registro via RPC
      console.log(`[registrar-conclusao-treino] 📞 Chamando RPC 'registrar_execucao_treino' para "${nome_treino}"...`);
      const data_treino = new Date().toLocaleDateString('en-CA', {
        timeZone: 'America/Sao_Paulo'
      });
      const { error: rpcError } = await supabase.rpc('registrar_execucao_treino', {
        p_aluno_id: aluno_id,
        p_nome_treino: nome_treino,
        p_descricao_atividade: null,
        p_duracao_minutos: duracao,
        p_observacoes: observacoes,
        p_data_treino: data_treino
      });
      if (rpcError) {
        // 3c. Gateway (Erro da RPC) - Lança o erro para o CATCH
        console.warn(`[registrar-conclusao-treino] ⚠️ Erro da RPC: ${rpcError.message}`);
        if (rpcError.message.includes("não encontrado")) {
          throw new Error(`Não encontrei o treino "${nome_treino}" no seu programa ativo. Por favor, tente registrar novamente com o nome correto.`);
        } else if (rpcError.message.includes("Já existe registro")) {
          throw new Error("Você já registrou esse treino hoje. Não é possível registrar duplicatas.");
        } else {
          throw new Error(`Erro ao registrar: ${rpcError.message}`);
        }
      }
      // 3d. Sucesso
      console.log(`[registrar-conclusao-treino] ✅ RPC executada com sucesso.`);
      outputJsonString = JSON.stringify({
        status: "Sucesso",
        message: `Treino "${nome_treino}" concluído e registrado com sucesso! Parabéns pelo esforço! 💪`
      });
    } else {
      // ========================================
      // AÇÃO: Cancelar (Não)
      // ========================================
      console.log(`[registrar-conclusao-treino] ❌ Cancelado pelo usuário.`);
      outputJsonString = JSON.stringify({
        status: "Cancelado",
        message: "Ok, registro de treino cancelado."
      });
    }
    // 4. Finalizar o Tool Call (Caminho Feliz)
    console.log(`[registrar-conclusao-treino] 🤖 Finalizando tool call (Caminho Feliz)...`);
    mensagemEnviada = await finalizarToolCallEChamarWhatsApp(supabase, conversation_id, tool_call_id, outputJsonString, aluno_id);
    // 5. Limpar AMBOS os bloqueios (Caminho Feliz)
    console.log(`[registrar-conclusao-treino] 🧹 Limpando bloqueio NOVO (botoes_ativos): ${botao_id}`);
    await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    console.log(`[registrar-conclusao-treino] 🧹 Limpando bloqueio ANTIGO (alunos.aguardando_confirmacao)...`);
    await supabase.from('alunos').update({
      aguardando_confirmacao: null
    }).eq('id', aluno_id);
    console.log(`[registrar-conclusao-treino] ✅ Processo concluído com sucesso.`);
    return new Response(JSON.stringify({
      success: true,
      message: mensagemEnviada
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    // ========================================
    // ⬇️⬇️⬇️ "SUPER-CATCH" (v1.1.0) ⬇️⬇️⬇️
    // ========================================
    console.error(`[registrar-conclusao-treino] ❌ ERRO GERAL:`, error.message);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Tenta finalizar a conversa MESMO EM CASO DE ERRO
    if (conversation_id_para_limpeza && tool_call_id_para_limpeza && aluno_id_para_limpeza) {
      console.warn(`[registrar-conclusao-treino] ⚠️ Erro detectado. Tentando finalizar tool call para desbloquear conversa...`);
      // ⬇️⬇️⬇️ INSTRUÇÃO PARA A LLM (COMO SOLICITADO) ⬇️⬇️⬇️
      const outputErro = JSON.stringify({
        status: "Erro",
        message: `Houve um erro (Detalhe: ${error.message}). Informe ao usuário que não foi possível registrar e que ele pode tentar novamente.`,
        instrucao_para_llm: "Os dados de input da tool não correspondem com os esperados pelo back end. Por favor, analise novamente o prompt E se o usuário Repetir a operação traga as informações corretas."
      });
      await finalizarToolCallEChamarWhatsApp(supabase, conversation_id_para_limpeza, tool_call_id_para_limpeza, outputErro, aluno_id_para_limpeza);
      console.log(`[registrar-conclusao-treino] ⚠️ Tool call de erro finalizado.`);
    } else {
      console.error(`[registrar-conclusao-treino] ❌ Erro crítico ANTES de carregar dados do botão. Não é possível finalizar tool call.`);
    }
    // 2. Tenta limpar os bloqueios do DB MESMO EM CASO DE ERRO
    console.warn(`[registrar-conclusao-treino] ⚠️ Tentando limpar bloqueios após erro...`);
    if (botao_id) {
      await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    }
    if (aluno_id_para_limpeza) {
      await supabase.from('alunos').update({
        aguardando_confirmacao: null
      }).eq('id', aluno_id_para_limpeza);
    }
    console.warn(`[registrar-conclusao-treino] ⚠️ Bloqueios limpos.`);
    // 3. Retorna o erro 500 para o log
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
