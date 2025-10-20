/**
 * @name orquestrador-ia
 * @version 5.0.0 (Conversations + Cache Otimizado + Function Calling Corrigido)
 * @author NutriCoach AI Development
 * @date 2025-10-20
 *
 * @description
 * Orquestrador que usa Conversations API da OpenAI para:
 * - Aproveitar cache de mensagens anteriores (custo infinitamente menor)
 * - Manter continuidade de contexto via conversation_id
 * - Encerrar corretamente o ciclo de function calling
 *
 * @changelog
 * - v5.0.0:
 *   - Uso de Conversations para cache automático
 *   - Correção do fluxo de function calling (segunda chamada)
 *   - Encerramento silencioso ou com resposta padrão configurável
 *   - Persistência robusta de conversation_id
 */

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
    console.log('[Orquestrador v5.0] 🚀 Iniciando processamento com Conversations + Cache');

    if (!mensagem_id) throw new Error("O 'mensagem_id' é obrigatório.");

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL'),
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
    );

    // ========================================
    // 1. BUSCAR MENSAGEM DO USUÁRIO
    // ========================================
    const { data: mensagemData, error: msgError } = await supabase
      .from('mensagens_temporarias')
      .select('aluno_id, mensagem')
      .eq('id', mensagem_id)
      .single();

    if (msgError) throw new Error(`Mensagem não encontrada: ${msgError.message}`);

    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;

    // ========================================
    // 2. BUSCAR PROMPT DINÂMICO + CONVERSATION_ID
    // ========================================
    const { data: promptData } = await supabase
      .from('dynamic_prompts')
      .select('id, prompt_final, conversation_id')
      .eq('aluno_id', aluno_id)
      .single();

    if (!promptData) throw new Error('Dynamic prompt não encontrado');

    let { prompt_final, conversation_id } = promptData as {
      prompt_final: string;
      conversation_id?: string
    };
    const promptId = (promptData as any).id;

    if (!prompt_final) throw new Error('prompt_final está vazio');

    console.log(`[Orquestrador] 📝 Prompt: ${prompt_final.length} chars`);
    console.log(`[Orquestrador] 🔗 Conversation ID: ${conversation_id || 'NULL (novo thread)'}`);

    // ========================================
    // 3. DEFINIR TOOLS (FUNCTION CALLING)
    // ========================================
    const tools = [
      {
        type: 'function',
        name: 'identificar_variacao_carga',
        description: 'Calcula a variação de carga proposta para um exercício e retorna o identificador, a variação de carga, e o nome do exercício.',
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
        description: 'Extrai informações de macronutrientes, valor calórico, tipo de refeição e consumo de líquidos de uma refeição informada pelo aluno.',
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
    ];

    // ========================================
    // 4. MONTAR PAYLOAD INICIAL
    // ========================================
    const payload: Record<string, unknown> = {
      model: Deno.env.get('OPENAI_MODEL') || 'gpt-4o-mini',
      input: perguntaUsuario,
      store: true,
      tools: tools
    };

    // Se conversation_id existe, usa para continuidade (CACHE!)
    if (conversation_id) {
      payload.conversation = conversation_id;
      console.log('[Orquestrador] 💰 Usando conversation para CACHE de mensagens anteriores');
    } else {
      // Primeira mensagem do thread - enviar instructions
      payload.instructions = prompt_final;
      console.log('[Orquestrador] 📤 Primeira mensagem - enviando instructions');
    }

    // ========================================
    // 5. PRIMEIRA CHAMADA À API
    // ========================================
    console.log('[Orquestrador] 📡 Fazendo primeira chamada à OpenAI...');

    const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(payload)
    });

    if (!openaiResponse.ok) {
      const errorBody = await openaiResponse.text();
      throw new Error(`Erro OpenAI: ${errorBody}`);
    }

    const responseData = await openaiResponse.json();

    console.log(`[Orquestrador] ✅ Response ID: ${responseData.id}`);
    console.log(`[Orquestrador] 🔗 Conversation ID (retornado): ${responseData.conversation_id || 'N/A'}`);

    // Métricas de cache
    const cachedTokens = responseData.usage?.input_tokens_details?.cached_tokens ?? 0;
    const inputTokens = responseData.usage?.input_tokens ?? 0;
    if (cachedTokens > 0) {
      const cachePercentage = ((cachedTokens / inputTokens) * 100).toFixed(1);
      console.log(`[Orquestrador] 💰 CACHE: ${cachedTokens}/${inputTokens} tokens (${cachePercentage}% cached)`);
    }

    // ========================================
    // 6. PERSISTIR CONVERSATION_ID
    // ========================================
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

    // ========================================
    // 7. DETECTAR SE HÁ FUNCTION CALL
    // ========================================
    let toolCallItem: any = null;

    for (let i = 0; i < (responseData.output?.length || 0); i++) {
      const item = responseData.output[i];
      if (item.type === 'function_call') {
        toolCallItem = item;
        console.log(`[Orquestrador] 🔧 Function call detectado: ${item.name}`);
        break;
      }
    }

    // ========================================
    // ROTA A: PROCESSAR FUNCTION CALL
    // ========================================
    if (toolCallItem) {
      console.log('[Orquestrador] 🔴 ROTA A: Processando function call...');

      let toolOutputText = '';
      let toolOutputObj: Record<string, unknown> = {};

      try {
        const toolArgs = typeof toolCallItem.arguments === 'string'
          ? JSON.parse(toolCallItem.arguments)
          : toolCallItem.arguments;

        // ========================================
        // 7A. EXECUTAR A FUNÇÃO
        // ========================================
        switch (toolCallItem.name) {
          case 'identificar_variacao_carga': {
            const { id_exercicio, variacao_de_carga, nome_exercicio } = toolArgs;

            if (!id_exercicio || variacao_de_carga === undefined) {
              throw new Error('Parâmetros inválidos para identificar_variacao_carga');
            }

            console.log(`[Orquestrador] 💪 Propondo carga: ${nome_exercicio} ${variacao_de_carga > 0 ? '+' : ''}${variacao_de_carga}kg`);

            const { error: rpcError } = await supabase.rpc('propor_atualizacao_carga', {
              p_exercicio_id: id_exercicio,
              p_variacao_kg: variacao_de_carga
            });

            if (rpcError) throw rpcError;

            toolOutputText = `Proposta de carga enviada com sucesso para aprovação do aluno via WhatsApp.`;
            toolOutputObj = {
              success: true,
              action: 'proposta_enviada',
              exercicio: nome_exercicio,
              variacao: variacao_de_carga
            };
            break;
          }

          case 'registrar_consumo': {
            const { refeicao, calorias, tipo, carboidratos, proteinas, gorduras, liquidos } = toolArgs;

            console.log(`[Orquestrador] 🍽️ Propondo registro: ${tipo} - ${calorias}kcal`);

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

            toolOutputText = `Registro de refeição proposto com sucesso para aprovação do aluno via WhatsApp.`;
            toolOutputObj = {
              success: true,
              action: 'registro_proposto',
              tipo,
              calorias
            };
            break;
          }

          default: {
            throw new Error(`Função não implementada: ${toolCallItem.name}`);
          }
        }

        console.log('[Orquestrador] ✅ Função executada com sucesso');

        // ========================================
        // 7B. FAZER SEGUNDA CHAMADA COM FUNCTION_CALL_OUTPUT
        // ========================================
        console.log('[Orquestrador] 🔄 Submetendo function_call_output...');

        const secondPayload: Record<string, unknown> = {
          model: Deno.env.get('OPENAI_MODEL') || 'gpt-4o-mini',
          conversation: conversation_id, // IMPORTANTE: Usar conversation_id
          input: [
            {
              type: 'function_call_output',
              call_id: toolCallItem.call_id,
              output: JSON.stringify(toolOutputObj)
            }
          ],
          store: true,
          tools: tools
        };

        const secondResponse = await fetch('https://api.openai.com/v1/responses', {
          method: 'POST',
          headers: {
            'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
            'Content-Type': 'application/json'
          },
          body: JSON.stringify(secondPayload)
        });

        if (!secondResponse.ok) {
          const errText = await secondResponse.text();
          throw new Error(`Erro ao submeter function_call_output: ${errText}`);
        }

        const secondResponseData = await secondResponse.json();

        console.log('[Orquestrador] ✅ Segunda chamada concluída');
        console.log(`[Orquestrador] 📊 Response ID final: ${secondResponseData.id}`);

        // Atualizar conversation_id se mudou
        if (secondResponseData.conversation_id && secondResponseData.conversation_id !== conversation_id) {
          await supabase
            .from('dynamic_prompts')
            .update({ conversation_id: secondResponseData.conversation_id })
            .eq('id', promptId);

          conversation_id = secondResponseData.conversation_id;
          console.log('[Orquestrador] 🔗 conversation_id atualizado');
        }

        // ========================================
        // 7C. EXTRAIR RESPOSTA FINAL DA IA
        // ========================================
        let respostaFinalIA = '';

        for (const item of secondResponseData.output || []) {
          if (item.type === 'message' && item.role === 'assistant') {
            const textContent = item.content?.find((c: any) => c.type === 'output_text');
            if (textContent) {
              respostaFinalIA = textContent.text;
              break;
            }
          }
        }

        // Se não houver resposta textual, usar mensagem padrão
        if (!respostaFinalIA) {
          respostaFinalIA = '✅ Dados processados com sucesso! Aguarde a confirmação.';
          console.log('[Orquestrador] ℹ️ Usando resposta padrão (sem output_text)');
        }

        console.log(`[Orquestrador] 💬 Resposta final: "${respostaFinalIA.substring(0, 100)}..."`);

        // ========================================
        // 7D. SALVAR E ENVIAR RESPOSTA
        // ========================================
        await supabase
          .from('mensagens_temporarias')
          .update({ resposta: respostaFinalIA })
          .eq('id', mensagem_id);

        // OPÇÃO 1: Enviar resposta da IA
        // OPÇÃO 2: Modo silencioso (não enviar nada)
        // Configurável via parâmetro

        const ENVIAR_RESPOSTA_TOOL_CALL = true; // Configurar aqui

        if (ENVIAR_RESPOSTA_TOOL_CALL && !nao_comunicar_aluno) {
          console.log('[Orquestrador] 📱 Enviando resposta da IA ao aluno...');
          await supabase.functions.invoke('enviar_menssagem_whatsapp', {
            body: { aluno_id, mensagem: respostaFinalIA }
          });
        } else {
          console.log('[Orquestrador] 🔇 Modo silencioso - resposta não enviada ao aluno');
        }

        // ========================================
        // 7E. REGISTRAR TOKENS (SOMA DAS DUAS CHAMADAS)
        // ========================================
        const totalInputTokens = (responseData.usage?.input_tokens ?? 0) +
                                  (secondResponseData.usage?.input_tokens ?? 0);
        const totalOutputTokens = (responseData.usage?.output_tokens ?? 0) +
                                   (secondResponseData.usage?.output_tokens ?? 0);
        const totalCachedTokens = (responseData.usage?.input_tokens_details?.cached_tokens ?? 0) +
                                   (secondResponseData.usage?.input_tokens_details?.cached_tokens ?? 0);

        supabase.functions.invoke('registrar-tokens', {
          body: {
            aluno_id,
            mensagem_id,
            modelo_utilizado: secondResponseData.model || responseData.model,
            input_tokens: totalInputTokens,
            cached_tokens: totalCachedTokens,
            output_tokens: totalOutputTokens,
            response_id: secondResponseData.id,
            conversation_id: conversation_id,
            tool_call_detectado: true
          }
        }).catch(console.error);

        console.log(`[Orquestrador] 📊 Tokens totais: ${totalInputTokens} input (${totalCachedTokens} cached), ${totalOutputTokens} output`);

        return new Response(JSON.stringify({
          success: true,
          rota: 'A',
          response_id: secondResponseData.id,
          conversation_id: conversation_id,
          cached_tokens: totalCachedTokens,
          resposta: respostaFinalIA
        }), {
          headers: { ...corsHeaders, 'Content-Type': 'application/json' },
          status: 200
        });

      } catch (toolError: any) {
        console.error('[Orquestrador] ❌ Erro ao processar tool:', toolError?.message);
        throw toolError;
      }
    }

    // ========================================
    // ROTA B: SEM FUNCTION CALL (RESPOSTA DIRETA)
    // ========================================
    console.log('[Orquestrador] 🟢 ROTA B: Sem function call - Resposta direta');

    let respostaIA = '';

    for (const item of responseData.output || []) {
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c: any) => c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }

    if (!respostaIA) throw new Error('Resposta vazia da IA');

    console.log(`[Orquestrador] 💬 Resposta: "${respostaIA.substring(0, 100)}..."`);

    // Salvar resposta
    await supabase
      .from('mensagens_temporarias')
      .update({ resposta: respostaIA })
      .eq('id', mensagem_id);

    // Enviar WhatsApp
    if (nao_comunicar_aluno === true) {
      console.log('[Orquestrador] 🔇 Modo silencioso');
      supabase.functions.invoke('extrair-macros-de-texto', {
        body: { texto_alimentos: respostaIA, aluno_id }
      }).catch(console.error);
    } else {
      console.log('[Orquestrador] 📱 Enviando WhatsApp...');
      await supabase.functions.invoke('enviar_menssagem_whatsapp', {
        body: { aluno_id, mensagem: respostaIA }
      });
    }

    // Registrar tokens
    supabase.functions.invoke('registrar-tokens', {
      body: {
        aluno_id,
        mensagem_id,
        modelo_utilizado: responseData.model,
        input_tokens: responseData.usage?.input_tokens ?? 0,
        cached_tokens: responseData.usage?.input_tokens_details?.cached_tokens ?? 0,
        output_tokens: responseData.usage?.output_tokens ?? 0,
        response_id: responseData.id,
        conversation_id: conversation_id,
        tool_call_detectado: false
      }
    }).catch(console.error);

    return new Response(JSON.stringify({
      success: true,
      rota: 'B',
      response_id: responseData.id,
      conversation_id: conversation_id,
      cached_tokens: cachedTokens,
      resposta: respostaIA
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200
    });

  } catch (error: any) {
    console.error('[Orquestrador] ❌ ERRO:', error?.message);
    console.error('[Orquestrador] Stack:', error?.stack);

    if (mensagem_id) {
      const supabaseAdmin = createClient(
        Deno.env.get('SUPABASE_URL'),
        Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
      );

      await supabaseAdmin
        .from('mensagens_temporarias')
        .update({ resposta: `ERRO: ${error?.message}` })
        .eq('id', mensagem_id);
    }

    return new Response(JSON.stringify({
      error: error?.message || 'Erro desconhecido',
      stack: error?.stack
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 500
    });
  }
});
