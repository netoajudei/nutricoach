/**
 * @name orquestrador-ia
 * @version 10.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 01:10:00 -03:00
 * 
 * @description
 * Orquestrador principal usando Conversations API da OpenAI.
 * Gerencia conversas, detecta tool calls e aciona funções backend.
 * 
 * @changelog
 * - v10.0.0 (2025-11-04): Implementado sistema de bloqueio educado
 *   - Orquestrador agora passa conversation_id e tool_call_id para funções propor
 *   - Orquestrador ENCERRA após invocar funções propor (não finaliza function calling)
 *   - Bloqueio permanece ativo até confirmação/cancelamento do usuário
 *   - Alterado propor_atualizacao_carga de RPC para Edge Function
 * 
 * @workflow
 * ROTA A (Com Tool Call):
 * 1. Detecta tool call (registrar_consumo ou identificar_variacao_carga)
 * 2. Invoca função propor correspondente passando conversation_id e tool_call_id
 * 3. ENCERRA (não finaliza function calling, não envia resposta)
 * 
 * ROTA B (Sem Tool Call):
 * 1. Envia resposta normal ao usuário
 * 2. Registra tokens
 * 3. Retorna sucesso
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') || 'gpt-5-mini';
serve(async (req)=>{
  if (req.method === 'OPTIONS') {
    return new Response('ok', {
      headers: corsHeaders
    });
  }
  const body = await req.json().catch(()=>({}));
  const mensagem_id = body.mensagem_id;
  try {
    console.log('[Orquestrador v10.0.0] 🚀 Conversations API + Bloqueio Educado');
    if (!mensagem_id) throw new Error("O 'mensagem_id' é obrigatório.");
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. BUSCAR MENSAGEM
    // ============================================
    const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').select('aluno_id, mensagem').eq('id', mensagem_id).single();
    if (msgError) throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    // ============================================
    // 2. BUSCAR PROMPT DINÂMICO + CONVERSATION_ID
    // ============================================
    const { data: promptData } = await supabase.from('dynamic_prompts').select('id, prompt_final, conversation_id').eq('aluno_id', aluno_id).single();
    if (!promptData) throw new Error('Dynamic prompt não encontrado');
    let { prompt_final, conversation_id } = promptData;
    const promptId = promptData.id;
    if (!prompt_final) throw new Error('prompt_final está vazio');
    console.log(`[Orquestrador] Prompt: ${prompt_final.length} chars`);
    console.log(`[Orquestrador] Conversation ID: ${conversation_id || 'NULL (criar novo)'}`);
    // ============================================
    // 3. CRIAR CONVERSATION SE NÃO EXISTIR
    // ============================================
    if (!conversation_id) {
      console.log('[Orquestrador] 📝 Criando nova conversation...');
      const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify({
          metadata: {
            aluno_id: aluno_id,
            tipo: 'coaching_nutricional'
          }
        })
      });
      if (!createConvResponse.ok) {
        const errorText = await createConvResponse.text();
        throw new Error(`Erro ao criar conversation: ${errorText}`);
      }
      const convData = await createConvResponse.json();
      conversation_id = convData.id;
      console.log(`[Orquestrador] ✅ Conversation criada: ${conversation_id}`);
      await supabase.from('dynamic_prompts').update({
        conversation_id: conversation_id
      }).eq('id', promptId);
    }
    // ============================================
    // 4. DEFINIR TOOLS
    // ============================================
    const tools = [
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
    ];
    // ============================================
    // 5. ENVIAR MENSAGEM USANDO CONVERSATIONS
    // ============================================
    console.log('[Orquestrador] 📤 Enviando mensagem...');
    const payload = {
      model: OPENAI_MODEL,
      conversation: conversation_id,
      store: true,
      instructions: prompt_final,
      input: perguntaUsuario,
      tools: tools
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
      const errorBody = await openaiResponse.text();
      throw new Error(`Erro OpenAI: ${errorBody}`);
    }
    const responseData = await openaiResponse.json();
    console.log(`[Orquestrador] ✅ Response ID: ${responseData.id}`);
    console.log(`[Orquestrador] 📊 Tokens: Input=${responseData.usage?.input_tokens}, Cached=${responseData.usage?.input_tokens_details?.cached_tokens ?? 0}`);
    // ============================================
    // 6. DETECTAR TOOL CALL NO OUTPUT
    // ============================================
    let toolCallItem = null;
    for (const item of responseData.output || []){
      if (item.type === 'function_call' || item.type === 'tool_call') {
        toolCallItem = item;
        console.log(`[Orquestrador] 🔧 Tool detectada: ${item.name}`);
        console.log(`[Orquestrador] 📋 Tool ID: ${item.id}`);
        break;
      }
    }
    // ============================================
    // ROTA A: COM TOOL CALL
    // ============================================
    if (toolCallItem) {
      console.log('[Orquestrador] 🔴 ROTA A: Processando tool call');
      try {
        const toolArgs = typeof toolCallItem.arguments === 'string' ? JSON.parse(toolCallItem.arguments) : toolCallItem.arguments;
        console.log('[Orquestrador] 📥 Argumentos:', toolArgs);
        // ============================================
        // EXECUTAR FUNÇÃO BACKEND
        // ============================================
        switch(toolCallItem.name){
          case 'identificar_variacao_carga':
            {
              const { id_exercicio, variacao_de_carga, nome_exercicio } = toolArgs;
              console.log('[Orquestrador] 💪 Executando identificar_variacao_carga');
              const { error: edgeError } = await supabase.functions.invoke('propor-atualizacao-carga', {
                body: {
                  exercicio_id: id_exercicio,
                  variacao_kg: variacao_de_carga,
                  conversation_id: conversation_id,
                  tool_call_id: toolCallItem.id
                }
              });
              if (edgeError) {
                console.error('[Orquestrador] ❌ Erro na Edge Function:', edgeError);
                throw edgeError;
              }
              console.log('[Orquestrador] ✅ Proposta de carga enviada, ENCERRANDO orquestrador');
              return new Response(JSON.stringify({
                success: true,
                awaiting_confirmation: true,
                message: 'Aguardando confirmação do usuário',
                tool: 'identificar_variacao_carga'
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                },
                status: 200
              });
            }
          case 'registrar_consumo':
            {
              const { refeicao, calorias, tipo, carboidratos, proteinas, gorduras, liquidos } = toolArgs;
              console.log('[Orquestrador] 🍽️ Executando registrar_consumo');
              const { error: edgeError } = await supabase.functions.invoke('propor-registro-refeicao', {
                body: {
                  aluno_id,
                  refeicao,
                  tipo,
                  calorias,
                  proteinas,
                  carboidratos,
                  gorduras,
                  liquidos_ml: typeof liquidos === 'number' ? liquidos * 1000 : liquidos,
                  conversation_id: conversation_id,
                  tool_call_id: toolCallItem.id
                }
              });
              if (edgeError) {
                console.error('[Orquestrador] ❌ Erro na Edge Function:', edgeError);
                throw edgeError;
              }
              console.log('[Orquestrador] ✅ Proposta de refeição enviada, ENCERRANDO orquestrador');
              return new Response(JSON.stringify({
                success: true,
                awaiting_confirmation: true,
                message: 'Aguardando confirmação do usuário',
                tool: 'registrar_consumo'
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                },
                status: 200
              });
            }
          default:
            throw new Error(`Função não implementada: ${toolCallItem.name}`);
        }
      } catch (toolError) {
        console.error('[Orquestrador] ❌ Erro ao processar tool:', toolError.message);
        throw toolError;
      }
    }
    // ============================================
    // ROTA B: SEM TOOL CALL
    // ============================================
    console.log('[Orquestrador] 🟢 ROTA B: Resposta normal');
    let respostaIA = '';
    for (const item of responseData.output || []){
      if (item.type === 'message' && item.role === 'assistant') {
        const textContent = item.content?.find((c)=>c.type === 'output_text');
        if (textContent) {
          respostaIA = textContent.text;
          break;
        }
      }
    }
    if (!respostaIA) throw new Error('Resposta vazia');
    console.log(`[Orquestrador] 💬 Resposta: ${respostaIA.substring(0, 100)}...`);
    await supabase.from('mensagens_temporarias').update({
      resposta: respostaIA
    }).eq('id', mensagem_id);
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id,
        mensagem: respostaIA
      }
    });
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
        api_response_body: responseData
      }
    }).catch(console.error);
    console.log('[Orquestrador] ✅ Concluído (ROTA B)');
    return new Response(JSON.stringify({
      success: true,
      rota: 'B',
      response_id: responseData.id,
      conversation_id: conversation_id
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
