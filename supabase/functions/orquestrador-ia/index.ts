/**
 * @name orquestrador-ia-final
 * @version 8.0.0
 * @description
 * FUNÇÃO 2 (que funciona) + previous_response_id da FUNÇÃO 1
 * - Detecta tools via output (function_call)
 * - Usa previous_response_id para histórico (não conversation_id)
 * - Tools EXATAS da função 2
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  const body = await req.json().catch(()=>({}));
  const mensagem_id = body.mensagem_id;
  try {
    console.log('[Orquestrador v8.0.0] Função 2 + previous_response_id da Função 1');
    if (!mensagem_id) throw new Error("O 'mensagem_id' é obrigatório.");
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // Buscar mensagem
    const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').select('aluno_id, mensagem').eq('id', mensagem_id).single();
    if (msgError) throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    // Buscar prompt dinâmico + last_response_id (NÃO conversation_id)
    const { data: promptData } = await supabase.from('dynamic_prompts').select('last_response_id, prompt_final').eq('aluno_id', aluno_id).single();
    if (!promptData) throw new Error('Dynamic prompt não encontrado');
    let { last_response_id, prompt_final } = promptData;
    if (!prompt_final) throw new Error('prompt_final está vazio');
    console.log(`[Orquestrador] Prompt: ${prompt_final.length} chars`);
    console.log(`[Orquestrador] Last response ID: ${last_response_id || 'NULL (primeira)'}`);
    // Montar payload (IGUAL FUNÇÃO 1: previous_response_id)
    const payload = {
      model: Deno.env.get('OPENAI_MODEL') || 'gpt-5-mini',
      instructions: prompt_final,
      input: perguntaUsuario,
      store: true,
      tools: [
        {
          type: 'function',
          name: 'identificar_variacao_carga',
          description: 'Calcula a variação de carga proposta para um exercício e retorna o identificador, a variação de carga, e o nome do exercício.',
          strict: true,
          parameters: {
            type: 'object',
            required: [
              'id_exercicio',
              'variacao_de_carga',
              'nome_exercicio'
            ],
            properties: {
              id_exercicio: {
                type: 'string'
              },
              variacao_de_carga: {
                type: 'number'
              },
              nome_exercicio: {
                type: 'string'
              }
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
            required: [
              'refeicao',
              'calorias',
              'tipo',
              'carboidratos',
              'proteinas',
              'gorduras',
              'liquidos'
            ],
            properties: {
              refeicao: {
                type: 'string'
              },
              calorias: {
                type: 'number'
              },
              tipo: {
                type: 'string'
              },
              carboidratos: {
                type: 'number'
              },
              proteinas: {
                type: 'number'
              },
              gorduras: {
                type: 'number'
              },
              liquidos: {
                type: 'number'
              }
            },
            additionalProperties: false
          }
        }
      ]
    };
    // CRÍTICO: Usa previous_response_id (FUNÇÃO 1)
    if (last_response_id) {
      payload.previous_response_id = last_response_id;
      console.log('[Orquestrador] Usando previous_response_id para continuidade');
    } else {
      console.log('[Orquestrador] Primeira mensagem - sem previous_response_id');
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
    console.log(`[Orquestrador] Tokens: Input=${responseData.usage?.input_tokens}, Cached=${responseData.usage?.input_tokens_details?.cached_tokens ?? 0}`);
    // Detectar tool call (IGUAL FUNÇÃO 2: no output)
    let toolCallItem = null;
    console.log('[Orquestrador] 🔍 Verificando tool calls no output...');
    console.log(`[Orquestrador] Output length: ${responseData.output?.length || 0}`);
    for(let i = 0; i < (responseData.output?.length || 0); i++){
      const item = responseData.output[i];
      console.log(`[Orquestrador] Output[${i}]: type="${item.type}", name="${item.name || 'N/A'}"`);
      if (item.type === 'function_call' || item.type === 'tool_call') {
        toolCallItem = item;
        console.log(`[Orquestrador] 🔧 Tool call encontrado!`);
        console.log(`[Orquestrador] 📋 Tool completo:`, JSON.stringify(item, null, 2));
        break;
      }
    }
    // ROTA A: TOOL CALL (EXATAMENTE IGUAL FUNÇÃO 2)
    if (toolCallItem) {
      console.log('[Orquestrador] 🔴 ROTA A: Processando tool call');
      let respostaParaSalvar = '';
      let toolOutputObj = {};
      try {
        const toolArgs = typeof toolCallItem.arguments === 'string' ? JSON.parse(toolCallItem.arguments) : toolCallItem.arguments;
        console.log(`[Orquestrador] 📥 Argumentos parseados:`, JSON.stringify(toolArgs, null, 2));
        switch(toolCallItem.name){
          case 'identificar_variacao_carga':
            {
              const { id_exercicio, variacao_de_carga, nome_exercicio } = toolArgs;
              console.log('[Orquestrador] 💪 Executando identificar_variacao_carga');
              console.log(`   - id_exercicio: ${id_exercicio}`);
              console.log(`   - variacao_de_carga: ${variacao_de_carga}`);
              console.log(`   - nome_exercicio: ${nome_exercicio}`);
              if (!id_exercicio || variacao_de_carga === undefined) {
                throw new Error('Parâmetros inválidos para identificar_variacao_carga');
              }
              const { data: rpcData, error: rpcError } = await supabase.rpc('propor_atualizacao_carga', {
                p_exercicio_id: id_exercicio,
                p_variacao_kg: variacao_de_carga
              });
              if (rpcError) {
                console.error('[Orquestrador] ❌ Erro no RPC:', rpcError);
                throw rpcError;
              }
              console.log('[Orquestrador] ✅ RPC executado. Data:', rpcData);
              respostaParaSalvar = `[TOOL] Proposta de carga enviada: ${nome_exercicio} ${variacao_de_carga > 0 ? '+' : ''}${variacao_de_carga}kg`;
              toolOutputObj = {
                success: true,
                message: 'Proposta enviada ao aluno'
              };
              break;
            }
          case 'registrar_consumo':
            {
              const { refeicao, calorias, tipo, carboidratos, proteinas, gorduras, liquidos } = toolArgs;
              console.log('[Orquestrador] 🍽️ Executando registrar_consumo');
              console.log(`   - refeicao: ${refeicao}`);
              console.log(`   - calorias: ${calorias}`);
              console.log(`   - tipo: ${tipo}`);
              console.log(`   - carboidratos: ${carboidratos}`);
              console.log(`   - proteinas: ${proteinas}`);
              console.log(`   - gorduras: ${gorduras}`);
              console.log(`   - liquidos: ${liquidos}`);
              const bodyPayload = {
                aluno_id,
                refeicao,
                tipo,
                calorias,
                proteinas,
                carboidratos,
                gorduras,
                liquidos_ml: typeof liquidos === 'number' ? liquidos * 1000 : liquidos
              };
              console.log('[Orquestrador] 📤 Chamando propor-registro-refeicao...');
              const { data: edgeData, error: edgeError } = await supabase.functions.invoke('propor-registro-refeicao', {
                body: bodyPayload
              });
              if (edgeError) {
                console.error('[Orquestrador] ❌ Erro na Edge Function:', edgeError);
                throw edgeError;
              }
              console.log('[Orquestrador] ✅ Edge Function executada. Data:', edgeData);
              respostaParaSalvar = `[TOOL] Registro proposto: ${tipo} - ${calorias}kcal`;
              toolOutputObj = {
                success: true,
                message: 'Registro proposto ao aluno'
              };
              break;
            }
          default:
            {
              throw new Error(`Função não implementada: ${toolCallItem.name}`);
            }
        }
        // Encerramento do ciclo (IGUAL FUNÇÃO 2)
        console.log('[Orquestrador] 🔄 Submetendo tool_outputs...');
        const toolOutputsBody = {
          tool_outputs: [
            {
              tool_call_id: toolCallItem.id,
              output: JSON.stringify({
                ...toolOutputObj,
                fechamento: 'Informações processadas pelo backend e armazenadas.'
              })
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
          console.error('[Orquestrador] ❌ Erro ao submeter tool_outputs:', errText);
          throw new Error(`Erro ao submeter tool_outputs: ${errText}`);
        }
        const toolResultData = await toolResultResponse.json();
        console.log('[Orquestrador] ✅ Ciclo encerrado');
        // CRÍTICO: Salva last_response_id (FUNÇÃO 1)
        await supabase.from('dynamic_prompts').update({
          last_response_id: toolResultData.id
        }).eq('aluno_id', aluno_id);
        console.log('[Orquestrador] ✅ last_response_id atualizado');
        // Salvar resposta técnica
        await supabase.from('mensagens_temporarias').update({
          resposta: respostaParaSalvar
        }).eq('id', mensagem_id);
        // Registrar tokens
        supabase.functions.invoke('registrar-tokens', {
          body: {
            aluno_id,
            mensagem_id,
            modelo_utilizado: toolResultData.model || responseData.model,
            input_tokens: toolResultData.usage?.input_tokens ?? responseData.usage?.input_tokens ?? 0,
            cached_tokens: toolResultData.usage?.input_tokens_details?.cached_tokens ?? 0,
            output_tokens: toolResultData.usage?.output_tokens ?? responseData.usage?.output_tokens ?? 0,
            response_id: toolResultData.id,
            api_response_body: toolResultData
          }
        }).catch(console.error);
        console.log('[Orquestrador] ✅ Concluído (ROTA A)');
        return new Response(JSON.stringify({
          success: true,
          rota: 'A',
          response_id: toolResultData.id
        }), {
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json'
          },
          status: 200
        });
      } catch (toolError) {
        console.error('[Orquestrador] ❌ Erro ao processar tool:', toolError.message);
        throw toolError;
      }
    }
    // ROTA B: SEM TOOL CALL (IGUAL FUNÇÃO 2)
    console.log('[Orquestrador] 🟢 ROTA B: Sem tool call');
    let respostaIA = '';
    for(let i = 0; i < (responseData.output?.length || 0); i++){
      const item = responseData.output[i];
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) throw new Error('Resposta vazia');
    // CRÍTICO: Salva last_response_id (FUNÇÃO 1)
    await supabase.from('dynamic_prompts').update({
      last_response_id: responseData.id
    }).eq('aluno_id', aluno_id);
    console.log('[Orquestrador] ✅ last_response_id atualizado');
    // Salvar resposta
    await supabase.from('mensagens_temporarias').update({
      resposta: respostaIA
    }).eq('id', mensagem_id);
    // Enviar WhatsApp
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id,
        mensagem: respostaIA
      }
    });
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
        api_response_body: responseData
      }
    }).catch(console.error);
    console.log('[Orquestrador] ✅ Concluído (ROTA B)');
    return new Response(JSON.stringify({
      success: true,
      rota: 'B',
      response_id: responseData.id
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[Orquestrador] ❌ ERRO:', error.message);
    if (mensagem_id) {
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      await supabaseAdmin.from('mensagens_temporarias').update({
        resposta: `ERRO: ${error.message}`
      }).eq('id', mensagem_id);
    }
    return new Response(JSON.stringify({
      error: error.message
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 500
    });
  }
});
