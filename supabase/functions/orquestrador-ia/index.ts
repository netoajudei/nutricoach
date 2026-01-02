/**
 * @name orquestrador-ia
 * @version 11.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 22:45:00 -03:00
 * 
 * @description
 * Orquestrador principal usando Conversations API da OpenAI.
 * Agora com sistema de ferramentas DINÂMICO carregado do banco de dados.
 * 
 * @changelog
 * - v11.0.0 (2025-11-04): Sistema de ferramentas dinâmico
 *   - Tools carregadas da tabela funcoes_ia
 *   - Roteamento dinâmico via coluna edge_function
 *   - Formato padronizado de chamadas (aluno_id, conversation_id, tool_call_id, argumentos)
 *   - Código simplificado sem switch gigante
 * 
 * @workflow
 * ROTA A (Com Tool Call):
 * 1. Detecta tool call
 * 2. Busca edge_function correspondente no banco
 * 3. Invoca edge function com formato padronizado
 * 4. ENCERRA
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
    console.log('[Orquestrador v11.0.0] 🚀 Sistema Dinâmico de Ferramentas');
    if (!mensagem_id) {
      throw new Error("O 'mensagem_id' é obrigatório.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. BUSCAR MENSAGEM
    // ============================================
    console.log('[Orquestrador] 1. Buscando mensagem:', mensagem_id);
    const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').select('aluno_id, mensagem').eq('id', mensagem_id).single();
    if (msgError) {
      throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    }
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    console.log('[Orquestrador] ✅ Aluno ID:', aluno_id);
    console.log('[Orquestrador] ✅ Mensagem:', perguntaUsuario.substring(0, 50) + '...');
    // ============================================
    // 2. BUSCAR PROMPT DINÂMICO + CONVERSATION_ID
    // ============================================
    console.log('[Orquestrador] 2. Buscando prompt dinâmico...');
    const { data: promptData, error: promptError } = await supabase.from('dynamic_prompts').select('id, prompt_final, conversation_id').eq('aluno_id', aluno_id).single();
    if (promptError || !promptData) {
      throw new Error('Dynamic prompt não encontrado');
    }
    let { prompt_final, conversation_id } = promptData;
    const promptId = promptData.id;
    if (!prompt_final) {
      throw new Error('prompt_final está vazio');
    }
    console.log('[Orquestrador] ✅ Prompt:', prompt_final.length, 'chars');
    console.log('[Orquestrador] ✅ Conversation ID:', conversation_id || 'NULL (criar novo)');
    // ============================================
    // 3. CRIAR CONVERSATION SE NÃO EXISTIR
    // ============================================
    if (!conversation_id) {
      console.log('[Orquestrador] 3. Conversation não existe - delegando para iniciar-conversa');
      await supabase.functions.invoke('iniciar-conversa', {
        body: {
          aluno_id: aluno_id,
          mensagem_id: mensagem_id
        }
      });
      console.log('[Orquestrador] ⏸️ ENCERRADO (iniciar-conversa assumiu controle)');
      return new Response(JSON.stringify({
        success: true,
        delegated_to: 'iniciar-conversa',
        message: 'Processamento delegado - iniciar-conversa chamará orquestrador novamente'
      }), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        },
        status: 200
      });
    }
    // ============================================
    // 4. DEFINIR TOOLS (DINAMICAMENTE)
    // ============================================
    console.log('[Orquestrador] 4. Buscando ferramentas ativas do banco...');
    let tools = [];
    const { data: funcoesData, error: funcoesError } = await supabase.from('funcoes_ia').select('definicao_openai').eq('is_active', true);
    if (funcoesError) {
      console.error('[Orquestrador] 🔥 Erro ao buscar funções:', funcoesError.message);
      throw new Error(`Falha ao carregar ferramentas: ${funcoesError.message}`);
    }
    if (!funcoesData || funcoesData.length === 0) {
      console.warn('[Orquestrador] ⚠️ Nenhuma função ativa no banco');
    } else {
      tools = funcoesData.map((item)=>item.definicao_openai);
      const nomesDasTools = tools.map((t)=>t.name).join(', ');
      console.log(`[Orquestrador] ✅ ${tools.length} ferramentas carregadas: [${nomesDasTools}]`);
    }
    // ============================================
    // 5. ENVIAR MENSAGEM PARA OPENAI
    // ============================================
    console.log('[Orquestrador] 5. Enviando mensagem para OpenAI...');
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
    console.log('[Orquestrador] ✅ Response ID:', responseData.id);
    console.log('[Orquestrador] 📊 Input tokens:', responseData.usage?.input_tokens);
    console.log('[Orquestrador] 📊 Cached tokens:', responseData.usage?.input_tokens_details?.cached_tokens ?? 0);
    console.log('[Orquestrador] 📊 Output tokens:', responseData.usage?.output_tokens);
    // ============================================
    // 6. DETECTAR TOOL CALL NO OUTPUT
    // ============================================
    let toolCallItem = null;
    for (const item of responseData.output || []){
      if (item.type === 'function_call' || item.type === 'tool_call') {
        toolCallItem = item;
        console.log('[Orquestrador] 🔧 Tool detectada:', item.name);
        console.log('[Orquestrador] 🆔 Call ID:', item.call_id);
        break;
      }
    }
    // ============================================
    // ROTA A: COM TOOL CALL
    // ============================================
    if (toolCallItem) {
      console.log('[Orquestrador] 🔴 ROTA A: Processando tool call');
      try {
        // Parse dos argumentos
        const toolArgs = typeof toolCallItem.arguments === 'string' ? JSON.parse(toolCallItem.arguments) : toolCallItem.arguments;
        console.log('[Orquestrador] 📥 Argumentos:', toolArgs);
        // ============================================
        // BUSCAR EDGE FUNCTION NO BANCO
        // ============================================
        console.log('[Orquestrador] 🔍 Buscando edge function para:', toolCallItem.name);
        const { data: funcaoData, error: funcaoError } = await supabase.from('funcoes_ia').select('edge_function, nome_funcao').eq('nome_funcao', toolCallItem.name).eq('is_active', true).single();
        if (funcaoError) {
          console.error('[Orquestrador] ❌ Erro SQL:', funcaoError);
          throw new Error(`Erro ao buscar função: ${funcaoError.message}`);
        }
        if (!funcaoData) {
          console.error('[Orquestrador] ❌ Nenhum dado retornado para:', toolCallItem.name);
          throw new Error(`Função ${toolCallItem.name} não encontrada no banco`);
        }
        const edgeFunctionName = funcaoData.edge_function;
        console.log('[Orquestrador] ✅ Edge Function:', edgeFunctionName);
        // ============================================
        // INVOCAR EDGE FUNCTION (FORMATO PADRONIZADO)
        // ============================================
        console.log('[Orquestrador] 🚀 Invocando', edgeFunctionName);
        const { error: edgeError } = await supabase.functions.invoke(edgeFunctionName, {
          body: {
            aluno_id: aluno_id,
            conversation_id: conversation_id,
            tool_call_id: toolCallItem.call_id,
            argumentos: toolArgs
          }
        });
        if (edgeError) {
          console.error('[Orquestrador] ❌ Erro na Edge Function:', edgeError);
          throw edgeError;
        }
        console.log('[Orquestrador] ✅ Edge function executada com sucesso');
        console.log('[Orquestrador] ⏸️ ENCERRANDO (aguardando confirmação)');
        return new Response(JSON.stringify({
          success: true,
          rota: 'A',
          tool: toolCallItem.name,
          awaiting_confirmation: true,
          message: 'Aguardando confirmação do usuário'
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
    // ============================================
    // ROTA B: SEM TOOL CALL (RESPOSTA NORMAL)
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
    if (!respostaIA) {
      throw new Error('Resposta vazia da IA');
    }
    console.log('[Orquestrador] 💬 Resposta:', respostaIA.substring(0, 100) + '...');
    // Salvar resposta no banco
    await supabase.from('mensagens_temporarias').update({
      resposta: respostaIA
    }).eq('id', mensagem_id);
    // Enviar resposta ao usuário
    await supabase.functions.invoke('enviar_menssagem_whatsapp_oficial', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
    // Registrar tokens (assíncrono)
    supabase.functions.invoke('registrar-tokens', {
      body: {
        aluno_id: aluno_id,
        mensagem_id: mensagem_id,
        modelo_utilizado: responseData.model,
        input_tokens: responseData.usage?.input_tokens ?? 0,
        cached_tokens: responseData.usage?.input_tokens_details?.cached_tokens ?? 0,
        output_tokens: responseData.usage?.output_tokens ?? 0,
        response_id: responseData.id,
        conversation_id: conversation_id,
        api_response_body: responseData
      }
    }).catch((err)=>{
      console.error('[Orquestrador] ⚠️ Erro ao registrar tokens:', err);
    });
    console.log('[Orquestrador] ✅ CONCLUÍDO (ROTA B)');
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
    console.error('[Orquestrador] Stack:', error.stack);
    // Tentar salvar erro na mensagem
    if (mensagem_id) {
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      const { error: updateError } = await supabaseAdmin.from('mensagens_temporarias').update({
        resposta: `ERRO: ${error.message}`
      }).eq('id', mensagem_id);
      if (updateError) {
        console.error('[Orquestrador] Erro ao salvar mensagem de erro:', updateError);
      }
    }
    return new Response(JSON.stringify({
      error: error.message,
      stack: error.stack
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 500
    });
  }
});
