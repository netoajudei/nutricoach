/**
 * @name finalizar-registro-refeicao
 * @version 1.4.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-07
 *
 * @changelog
 * - v1.4.0:
 * - Implementado o "Super-Catch" de segurança.
 * - O 'catch' principal agora é capaz de chamar 'finalizarToolCallEChamarWhatsApp'
 * em caso de qualquer erro (ex: 'invalid input syntax').
 * - Isso garante que o tool call seja finalizado e o usuário seja notificado,
 * evitando que a conversa fique bloqueada.
 * - Variáveis de limpeza (conversation_id, tool_call_id) movidas para
 * o escopo principal para estarem acessíveis no 'catch'.
 * - v1.3.0:
 * - Adicionado 'Math.round()' para corrigir o erro 'invalid input syntax'.
 * - v1.2.0:
 * - Implementado helper de finalização de tool call 'Padrão v1.2'.
 *
 * @description
 * 1. Recebe 'botao_id' e 'confirmado'.
 * 2. Busca 'botoes_ativos' para obter todos os IDs de conversa.
 * 3. Tenta processar a lógica (arredondar e inserir no DB).
 * 4. Se FALHAR (em qualquer etapa, ex: 'invalid input'):
 * - O 'catch' principal assume.
 * - Chama 'finalizarToolCall' com uma mensagem de erro genérica.
 * - Limpa os bloqueios.
 * - Retorna 500, mas a conversa do usuário já foi desbloqueada.
 * 5. Se TIVER SUCESSO:
 * - Chama 'finalizarToolCall' com a mensagem de sucesso.
 * - Limpa os bloqueios.
 * - Retorna 200.
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
        respostaIA = "Ok, registrado!";
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
    console.log(`[finalizar-registro-refeicao] 🚀 Processando botão: ${botao_id} | Confirmado: ${confirmado}`);
    // 2. Buscar dados do botão ativo
    const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('aluno_id, conversation_id, tool_call_id, argumentos').eq('id', botao_id).single();
    if (botaoErr || !botao) {
      console.warn(`[finalizar-registro-refeicao] ⚠️ Botão ${botao_id} não encontrado. Pode já ter sido processado.`);
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
      console.log(`[finalizar-registro-refeicao] ✅ Confirmado. Registrando no histórico...`);
      const { refeicao, tipo, horario, calorias, proteinas, carboidratos, gorduras } = args;
      const liquidos_ml = args.liquidos_ml || args.liquidos || 0;
      const data_registro = new Date().toLocaleDateString('en-CA', {
        timeZone: 'America/Sao_Paulo'
      });
      // Arredonda os valores (Correção v1.3.0)
      const calorias_int = Math.round(calorias || 0);
      const proteinas_int = Math.round(proteinas || 0);
      const carboidratos_int = Math.round(carboidratos || 0);
      const gorduras_int = Math.round(gorduras || 0);
      const liquidos_int = Math.round(liquidos_ml || 0);
      const { error: insertError } = await supabase.from('daily_consumption_history').insert({
        aluno_id: aluno_id,
        data_registro: data_registro,
        consumo_calorias: calorias_int,
        consumo_proteina: proteinas_int,
        consumo_carboidrato: carboidratos_int,
        consumo_gordura: gorduras_int,
        consumo_agua_ml: liquidos_int,
        analise_qualitativa: `(${tipo} ${horario}) ${refeicao}`,
        confirmada: true
      });
      if (insertError) {
        // 🛑 O ERRO ACONTECE AQUI
        console.error(`[finalizar-registro-refeicao] ❌ Erro ao inserir no DB:`, insertError.message);
        // Lança o erro para ser pego pelo 'catch' principal
        throw new Error(`Erro ao salvar no histórico: ${insertError.message}`);
      }
      console.log(`[finalizar-registro-refeicao] ✅ Refeição inserida no histórico.`);
      outputJsonString = JSON.stringify({
        status: "Sucesso",
        message: "Refeição registrada com sucesso pelo usuário."
      });
    } else {
      // ========================================
      // AÇÃO: Cancelar (Não)
      // ========================================
      console.log(`[finalizar-registro-refeicao] ❌ Cancelado pelo usuário. Nenhum registro feito.`);
      outputJsonString = JSON.stringify({
        status: "Cancelado",
        message: "Usuário cancelou a operação. Nenhuma alteração foi feita."
      });
    }
    // 4. Finalizar o Tool Call (Caminho Feliz)
    console.log(`[finalizar-registro-refeicao] 🤖 Finalizando tool call (Caminho Feliz)...`);
    mensagemEnviada = await finalizarToolCallEChamarWhatsApp(supabase, conversation_id, tool_call_id, outputJsonString, aluno_id);
    // 5. Limpar AMBOS os bloqueios (Caminho Feliz)
    console.log(`[finalizar-registro-refeicao] 🧹 Limpando bloqueio NOVO (botoes_ativos): ${botao_id}`);
    await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    console.log(`[finalizar-registro-refeicao] 🧹 Limpando bloqueio ANTIGO (alunos.aguardando_confirmacao)...`);
    await supabase.from('alunos').update({
      aguardando_confirmacao: null
    }).eq('id', aluno_id);
    console.log(`[finalizar-registro-refeicao] ✅ Processo concluído com sucesso.`);
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
    // ⬇️⬇️⬇️ "SUPER-CATCH" (v1.4.0) ⬇️⬇️⬇️
    // ========================================
    console.error(`[finalizar-registro-refeicao] ❌ ERRO GERAL:`, error.message);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Tenta finalizar a conversa MESMO EM CASO DE ERRO
    if (conversation_id_para_limpeza && tool_call_id_para_limpeza && aluno_id_para_limpeza) {
      console.warn(`[finalizar-registro-refeicao] ⚠️ Erro detectado. Tentando finalizar tool call para desbloquear conversa...`);
      const outputErro = JSON.stringify({
        status: "Erro",
        // Mensagem para a IA:
        message: `Houve um erro interno (Detalhe: ${error.message}). Informe ao usuário que não foi possível registrar e que ele pode tentar novamente,***Nota para a llm ***Os dados de input da tool não correspondem com os esperados pelo back end. Por favor, analise novamente o prompt E se o usuário Repetir a operação traga as informações corretas NAO COMENTE ESSE DSADO ECNICO COM O USUARIO> APENAS DIGA U OCORREU UM ERRO E PECA PARA REPETIR O PROCESSO..`
      });
      await finalizarToolCallEChamarWhatsApp(supabase, conversation_id_para_limpeza, tool_call_id_para_limpeza, outputErro, aluno_id_para_limpeza);
      console.log(`[finalizar-registro-refeicao] ⚠️ Tool call de erro finalizado.`);
    } else {
      console.error(`[finalizar-registro-refeicao] ❌ Erro crítico ANTES de carregar dados do botão. Não é possível finalizar tool call.`);
    }
    // 2. Tenta limpar os bloqueios do DB MESMO EM CASO DE ERRO
    console.warn(`[finalizar-registro-refeicao] ⚠️ Tentando limpar bloqueios após erro...`);
    if (botao_id) {
      await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    }
    if (aluno_id_para_limpeza) {
      await supabase.from('alunos').update({
        aguardando_confirmacao: null
      }).eq('id', aluno_id_para_limpeza);
    }
    console.warn(`[finalizar-registro-refeicao] ⚠️ Bloqueios limpos.`);
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
