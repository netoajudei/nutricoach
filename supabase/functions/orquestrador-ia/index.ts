// @ts-nocheck
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  const body = await req.json().catch(() => ({}));
  const { mensagem_id, nao_comunicar_aluno } = body;
  try {
    console.log('[Orquestrador v4.1] Iniciando processamento com Conversations');
    if (!mensagem_id) throw new Error("O 'mensagem_id' é obrigatório.");
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // Buscar mensagem
    const { data: mensagemData, error: msgError } = await supabase
      .from('mensagens_temporarias')
      .select('aluno_id, mensagem')
      .eq('id', mensagem_id)
      .single();
    if (msgError) throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    // Buscar prompt dinâmico + conversation_id
    const { data: promptData } = await supabase
      .from('dynamic_prompts')
      .select('id, prompt_final, conversation_id')
      .eq('aluno_id', aluno_id)
      .single();
    if (!promptData) throw new Error('Dynamic prompt não encontrado');
    let { prompt_final, conversation_id } = promptData as { prompt_final: string; conversation_id?: string };
    const promptId = (promptData as any).id;
    if (!prompt_final) throw new Error('prompt_final está vazio');
    console.log(`[Orquestrador] Prompt: ${prompt_final.length} chars`);
    console.log(`[Orquestrador] Conversation ID atual: ${conversation_id || 'NULL (novo thread)'}`);
    // Montar payload para Responses API com Conversations
    const payload: Record<string, unknown> = {
      model: Deno.env.get('OPENAI_MODEL') || 'gpt-5-mini',
      instructions: prompt_final,
      input: perguntaUsuario,
      store: true,
      tools: [
        {
          type: 'function',
          name: 'identificar_variacao_carga',
          description:
            'Calcula a variação de carga proposta para um exercício e retorna o identificador, a variação de carga, e o nome do exercício.',
          strict: true,
          parameters: {
            type: 'object',
            required: ['id_exercicio', 'variacao_de_carga', 'nome_exercicio'],
            properties: {
              id_exercicio: { type: 'string' },
              variacao_de_carga: { type: 'number' },
              nome_exercicio: { type: 'string' }
            },
            additionalProperties: false
          }
        },
        {
          type: 'function',
          name: 'registrar_consumo',
          description:
            'Extrai informações de macronutrientes, valor calórico, tipo de refeição e consumo de líquidos de uma refeição informada pelo aluno.',
          strict: true,
          parameters: {
            type: 'object',
            required: ['refeicao', 'calorias', 'tipo', 'carboidratos', 'proteinas', 'gorduras', 'liquidos'],
            properties: {
              refeicao: { type: 'string' },
              calorias: { type: 'number' },
              tipo: { type: 'string' },
              carboidratos: { type: 'number' },
              proteinas: { type: 'number' },
              gorduras: { type: 'number' },
              liquidos: { type: 'number' }
            },
            additionalProperties: false
          }
        }
      ]
    };
    if (conversation_id) {
      (payload as any).conversation = conversation_id;
      console.log('[Orquestrador] Usando conversation_id para continuidade');
    } else {
      console.log('[Orquestrador] Primeira mensagem do thread - sem conversation_id');
    }
    // Chamar OpenAI Responses
    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });
    if (!openaiResponse.ok) {
      const errorBody = await openaiResponse.text();
      throw new Error(`Erro OpenAI: ${errorBody}`);
    }
    const responseData = await openaiResponse.json();
    console.log(`[Orquestrador] Response ID: ${responseData.id}`);
    console.log(`[Orquestrador] Conversation ID (retornado): ${responseData.conversation_id}`);
    // Persistir conversation_id de forma robusta
    if (responseData.conversation_id) {
      const { error: convErr } = await supabase
        .from('dynamic_prompts')
        .update({ conversation_id: responseData.conversation_id })
        .eq('id', promptId);
      if (convErr) {
        console.error('[Orquestrador] ❌ Erro ao salvar conversation_id:', convErr.message);
      } else {
        console.log('[Orquestrador] ✅ conversation_id salvo/atualizado');
      }
      conversation_id = responseData.conversation_id;
    }
    // Detectar tool call
    let toolCallItem: any = null;
    for (let i = 0; i < (responseData.output?.length || 0); i++) {
      const item = responseData.output[i];
      if (item.type === 'function_call' || item.type === 'tool_call') {
        toolCallItem = item;
        break;
      }
    }
    // ROTA A: TOOL CALL
    if (toolCallItem) {
      console.log('[Orquestrador] 🔴 ROTA A: Processando tool call...');
      let respostaParaSalvar = '';
      let toolOutputObj: Record<string, unknown> = {};
      try {
        const toolArgs = typeof toolCallItem.arguments === 'string'
          ? JSON.parse(toolCallItem.arguments)
          : toolCallItem.arguments;
        switch (toolCallItem.name) {
          case 'identificar_variacao_carga': {
            const { id_exercicio, variacao_de_carga, nome_exercicio } = toolArgs;
            if (!id_exercicio || variacao_de_carga === undefined) {
              throw new Error('Parâmetros inválidos para identificar_variacao_carga');
            }
            const { error: rpcError } = await supabase.rpc('propor_atualizacao_carga', {
              p_exercicio_id: id_exercicio,
              p_variacao_kg: variacao_de_carga
            });
            if (rpcError) throw rpcError;
            respostaParaSalvar = `[TOOL] Proposta de carga enviada: ${nome_exercicio} ${variacao_de_carga > 0 ? '+' : ''}${variacao_de_carga}kg`;
            toolOutputObj = { success: true, message: 'Proposta enviada ao aluno' };
            break;
          }
          case 'registrar_consumo': {
            const { refeicao, calorias, tipo, carboidratos, proteinas, gorduras, liquidos } = toolArgs;
            const { error: edgeError } = await supabase.functions.invoke('propor-registro-refeicao', {
              body: {
                aluno_id,
                refeicao,
                tipo,
                calorias,
                proteinas,
                carboidratos,
                gorduras,
                liquidos_ml: (typeof liquidos === 'number' ? liquidos * 1000 : liquidos)
              }
            });
            if (edgeError) throw edgeError;
            respostaParaSalvar = `[TOOL] Registro proposto: ${tipo} - ${calorias}kcal`;
            toolOutputObj = { success: true, message: 'Registro proposto ao aluno' };
            break;
          }
          default: {
            throw new Error(`Função não implementada: ${toolCallItem.name}`);
          }
        }
        // Encerramento do ciclo via endpoint dedicado de tool outputs (Conversations)
        console.log('[Orquestrador] 🔄 Submetendo tool_outputs para encerrar ciclo...');
        const toolOutputsBody = {
          tool_outputs: [
            {
              tool_call_id: toolCallItem.id,
              output: JSON.stringify({ ...toolOutputObj, fechamento: 'Informações processadas pelo backend e armazenadas.' })
            }
          ]
        };
        const toolResultResponse = await fetch(`https://api.openai.com/v1/responses/${responseData.id}/tool_outputs`, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify(toolOutputsBody)
        });
        if (!toolResultResponse.ok) {
          const errText = await toolResultResponse.text();
          throw new Error(`Erro ao submeter tool_outputs: ${errText}`);
        }
        const toolResultData = await toolResultResponse.json();
        console.log('[Orquestrador] ✅ Ciclo encerrado com tool_result');
        // Persistir conversation_id (caso tenha mudado)
        if (toolResultData.conversation_id && toolResultData.conversation_id !== conversation_id) {
          const { error: convErr2 } = await supabase
            .from('dynamic_prompts')
            .update({ conversation_id: toolResultData.conversation_id })
            .eq('id', promptId);
          if (convErr2) {
            console.error('[Orquestrador] ❌ Erro ao salvar conversation_id (tool_result):', convErr2.message);
          } else {
            console.log('[Orquestrador] ✅ conversation_id atualizado após tool_result');
          }
          conversation_id = toolResultData.conversation_id;
        }
        // Salvar resposta técnica (não enviada ao aluno)
        await supabase.from('mensagens_temporarias').update({ resposta: respostaParaSalvar }).eq('id', mensagem_id);
        // Registrar tokens (assíncrono)
        supabase.functions.invoke('registrar-tokens', {
          body: {
            aluno_id,
            mensagem_id,
            modelo_utilizado: toolResultData.model || responseData.model,
            input_tokens: toolResultData.usage?.input_tokens ?? responseData.usage?.input_tokens ?? 0,
            output_tokens: toolResultData.usage?.output_tokens ?? responseData.usage?.output_tokens ?? 0,
            response_id: toolResultData.id,
            conversation_id: conversation_id,
            tool_call_detectado: true
          }
        }).catch(console.error);
        return new Response(JSON.stringify({ success: true, rota: 'A', response_id: toolResultData.id }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200
        });
      } catch (toolError: any) {
        console.error('[Orquestrador] ❌ Erro ao processar tool:', toolError?.message);
        throw toolError;
      }
    }
    // ROTA B: SEM TOOL CALL
    console.log('[Orquestrador] 🟢 ROTA B: Sem tool call - Processamento normal');
    let respostaIA = '';
    for (let i = 0; i < (responseData.output?.length || 0); i++) {
      const item = responseData.output[i];
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c: any) => c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) throw new Error('Resposta vazia');
    // Persistir conversation_id (garantia)
    if (responseData.conversation_id) {
      const { error: convErr3 } = await supabase
        .from('dynamic_prompts')
        .update({ conversation_id: responseData.conversation_id })
        .eq('id', promptId);
      if (convErr3) {
        console.error('[Orquestrador] ❌ Erro ao salvar conversation_id (rota B):', convErr3.message);
      } else {
        console.log('[Orquestrador] ✅ conversation_id salvo/atualizado (rota B)');
      }
      conversation_id = responseData.conversation_id;
    }
    // Salvar resposta
    await supabase.from('mensagens_temporarias').update({ resposta: respostaIA }).eq('id', mensagem_id);
    // Comunicação com aluno
    if (nao_comunicar_aluno === true) {
      console.log('[Orquestrador] Modo Silencioso');
      supabase.functions.invoke('extrair-macros-de-texto', {
        body: { texto_alimentos: respostaIA, aluno_id }
      }).catch(console.error);
    } else {
      await supabase.functions.invoke('enviar_menssagem_whatsapp', { body: { aluno_id, mensagem: respostaIA } });
    }
    supabase.functions.invoke('registrar-tokens', {
      body: {
        aluno_id,
        mensagem_id,
        modelo_utilizado: responseData.model,
        input_tokens: responseData.usage?.input_tokens ?? 0,
        output_tokens: responseData.usage?.output_tokens ?? 0,
        response_id: responseData.id,
        conversation_id: conversation_id ?? responseData.conversation_id,
        tool_call_detectado: false
      }
    }).catch(console.error);
    return new Response(JSON.stringify({ success: true, rota: 'B', response_id: responseData.id }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    });
  } catch (error: any) {
    console.error('[Orquestrador] ❌ Erro:', error?.message);
    if (mensagem_id) {
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      await supabaseAdmin.from('mensagens_temporarias').update({ resposta: `ERRO: ${error?.message}` }).eq('id', mensagem_id);
    }
    return new Response(JSON.stringify({ error: (error?.message || 'Erro desconhecido') }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500
    });
  }
});
