/**
 * @name orquestrador-ia
 * @version 11.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 09:50:00 -10:00
 * 
 * @description
 * Orquestrador principal usando Conversations API da OpenAI.
 * Gerencia conversas, detecta tool calls e aciona funções backend.
 * 
 * @changelog
 * - v11.0.0 (2025-11-04): SIMPLIFICAÇÃO TOTAL
 *   - Orquestrador APENAS invoca funções propor e ENCERRA
 *   - NÃO finaliza function calling (será feito nos botões)
 *   - NÃO envia resposta ao usuário (será feito nos botões)
 *   - Passa conversation_id e tool_call_id para funções propor
 *   - Bloqueio permanece ativo até confirmação/cancelamento
 * 
 * @workflow
 * ROTA A (Com Tool Call):
 * 1. Detecta tool call
 * 2. Invoca função propor passando conversation_id e tool_call_id
 * 3. ENCERRA (fim do processo)
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
    console.log('[Orquestrador v11.0.0] 🚀 Iniciando');
    if (!mensagem_id) {
      throw new Error("O 'mensagem_id' é obrigatório.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. BUSCAR MENSAGEM
    // ============================================
    console.log('[Orquestrador] 📨 Buscando mensagem:', mensagem_id);
    const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').select('aluno_id, mensagem').eq('id', mensagem_id).single();
    if (msgError) {
      throw new Error(`Mensagem não encontrada: ${msgError.message}`);
    }
    const { aluno_id, mensagem: perguntaUsuario } = mensagemData;
    console.log('[Orquestrador] ✅ Mensagem encontrada');
    console.log('[Orquestrador] 👤 Aluno ID:', aluno_id);
    console.log('[Orquestrador] 💬 Pergunta:', perguntaUsuario.substring(0, 50));
    // ============================================
    // 2. BUSCAR PROMPT DINÂMICO + CONVERSATION_ID
    // ============================================
    console.log('[Orquestrador] 📋 Buscando prompt dinâmico...');
    const { data: promptData } = await supabase.from('dynamic_prompts').select('id, prompt_final, conversation_id').eq('aluno_id', aluno_id).single();
    if (!promptData) {
      throw new Error('Dynamic prompt não encontrado');
    }
    let { prompt_final, conversation_id } = promptData;
    const promptId = promptData.id;
    if (!prompt_final) {
      throw new Error('prompt_final está vazio');
    }
    console.log('[Orquestrador] ✅ Prompt carregado:', prompt_final.length, 'chars');
    console.log('[Orquestrador] 📞 Conversation ID:', conversation_id || 'NULL (criar novo)');
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
      console.log('[Orquestrador] ✅ Conversation criada:', conversation_id);
      // Salvar no banco
      await supabase.from('dynamic_prompts').update({
        conversation_id: conversation_id
      }).eq('id', promptId);
      console.log('[Orquestrador] ✅ Conversation ID salvo no banco');
    }
    // ============================================
    // 4. DEFINIR TOOLS (DINAMICAMENTE)
    // ============================================
    // Esta lógica agora busca as ferramentas dinamicamente
    // da tabela 'funcoes_ia' no banco de dados.
    let tools = []; // Inicializa a lista de ferramentas como vazia
    try {
      console.log('[Orquestrador] 4. Buscando ferramentas (funções) ativas do banco de dados...');
      // 1. Faz a consulta ao banco de dados
      const { data: funcoesData, error: funcoesError } = await supabase.from('funcoes_ia').select('definicao_openai') // Pega SÓ a coluna com o JSON da OpenAI
      .eq('is_active', true); // Filtra apenas pelas funções ativas
      if (funcoesError) {
        // Se a consulta falhar, registra o erro e lança
        console.error('🔥 Erro crítico ao buscar funções da IA:', funcoesError.message);
        throw new Error(`Falha ao carregar ferramentas da IA: ${funcoesError.message}`);
      }
      // 2. Processa os resultados
      if (!funcoesData || funcoesData.length === 0) {
        // Se não houver ferramentas, apenas avisa no log.
        // 'tools' continuará sendo um array vazio [].
        console.warn('⚠️ Nenhuma função/ferramenta da IA está ativa no banco de dados.');
      } else {
        // 3. Extrai as definições
        tools = funcoesData.map((item)=>item.definicao_openai);
        // Log de sucesso
        // =============================================================
        // <<-- ESTA É A LINHA CORRIGIDA -->>
        const nomesDasTools = tools.map((t)=>t.name).join(', ');
        // =============================================================
        console.log(`[Orquestrador] ✅ ${tools.length} ferramentas carregadas com sucesso: [${nomesDasTools}]`);
      }
    } catch (error) {
      // Captura qualquer erro no processo e o relança para parar a execução
      console.error('🔥 Erro fatal durante a inicialização das tools:', error.message);
      throw error;
    }
    // Ao final deste bloco, a variável 'tools' estará pronta (vazia ou preenchida)
    // para ser usada na chamada da API da OpenAI mais abaixo no seu código.
    // ============================================
    // 5. ENVIAR MENSAGEM PARA OPENAI
    // ============================================
    console.log('[Orquestrador] 📤 Enviando mensagem para OpenAI...');
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
    console.log('[Orquestrador] ✅ Resposta recebida');
    console.log('[Orquestrador] 🆔 Response ID:', responseData.id);
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
        console.log('[Orquestrador] 🆔 Tool ID:', item.id);
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
        console.log('[Orquestrador] 📥 Argumentos da tool:', toolArgs);
        // 🔍 CORREÇÃO: Usar call_id em vez de id
        const tool_call_id = toolCallItem.call_id;
        console.log('[Orquestrador] 🔍 DADOS PARA ENVIAR À FUNÇÃO:');
        console.log('[Orquestrador] - conversation_id:', conversation_id);
        console.log('[Orquestrador] - tool_call_id:', tool_call_id);
        console.log('[Orquestrador] - aluno_id:', aluno_id);
        // ============================================
        // SWITCH: EXECUTAR FUNÇÃO BACKEND
        // ============================================
        switch(toolCallItem.name){
          // ==========================================
          // CASE 1: IDENTIFICAR VARIAÇÃO DE CARGA
          // ==========================================
          case 'identificar_variacao_carga':
            {
              const { id_exercicio, variacao_de_carga, nome_exercicio } = toolArgs;
              console.log('[Orquestrador] 💪 Acionando propor-atualizacao-carga...');
              const { error: edgeError } = await supabase.functions.invoke('propor-atualizacao-carga', {
                body: {
                  exercicio_id: id_exercicio,
                  variacao_kg: variacao_de_carga,
                  conversation_id: conversation_id,
                  tool_call_id: tool_call_id
                }
              });
              if (edgeError) {
                console.error('[Orquestrador] ❌ Erro ao invocar propor-atualizacao-carga:', edgeError);
                throw edgeError;
              }
              console.log('[Orquestrador] ✅ Proposta de carga enviada');
              console.log('[Orquestrador] ⏸️ ENCERRANDO orquestrador (bloqueio ativo)');
              return new Response(JSON.stringify({
                success: true,
                rota: 'A',
                tool: 'identificar_variacao_carga',
                awaiting_confirmation: true,
                message: 'Aguardando confirmação do usuário'
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                },
                status: 200
              });
            }
          // ==========================================
          // CASE 2: REGISTRAR CONSUMO
          // ==========================================
          case 'registrar_consumo':
            {
              const { refeicao, calorias, tipo, carboidratos, proteinas, gorduras, liquidos } = toolArgs;
              console.log('[Orquestrador] 🍽️ Acionando propor-registro-refeicao...');
              const { error: edgeError } = await supabase.functions.invoke('propor-registro-refeicao', {
                body: {
                  aluno_id: aluno_id,
                  refeicao: refeicao,
                  tipo: tipo,
                  calorias: calorias,
                  proteinas: proteinas,
                  carboidratos: carboidratos,
                  gorduras: gorduras,
                  liquidos_ml: typeof liquidos === 'number' ? liquidos * 1000 : liquidos,
                  conversation_id: conversation_id,
                  tool_call_id: tool_call_id
                }
              });
              if (edgeError) {
                console.error('[Orquestrador] ❌ Erro ao invocar propor-registro-refeicao:', edgeError);
                throw edgeError;
              }
              console.log('[Orquestrador] ✅ Proposta de refeição enviada');
              console.log('[Orquestrador] ⏸️ ENCERRANDO orquestrador (bloqueio ativo)');
              return new Response(JSON.stringify({
                success: true,
                rota: 'A',
                tool: 'registrar_consumo',
                awaiting_confirmation: true,
                message: 'Aguardando confirmação do usuário'
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                },
                status: 200
              });
            }
          // ==========================================
          // DEFAULT: FUNÇÃO NÃO IMPLEMENTADA
          // ==========================================
          default:
            {
              throw new Error(`Função não implementada: ${toolCallItem.name}`);
            }
        }
      } catch (toolError) {
        console.error('[Orquestrador] ❌ Erro ao processar tool:', toolError.message);
        throw toolError;
      }
    }
    // ============================================
    // ROTA B: SEM TOOL CALL (RESPOSTA NORMAL)
    // ============================================
    console.log('[Orquestrador] 🟢 ROTA B: Resposta normal (sem tool call)');
    // Extrair resposta do output
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
    console.log('[Orquestrador] ✅ Resposta salva no banco');
    // Enviar resposta ao usuário
    console.log('[Orquestrador] 📱 Enviando resposta ao usuário...');
    await supabase.functions.invoke('enviar_menssagem_whatsapp', {
      body: {
        aluno_id: aluno_id,
        mensagem: respostaIA
      }
    });
    console.log('[Orquestrador] ✅ Resposta enviada ao WhatsApp');
    // Registrar tokens (assíncrono, não aguarda)
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
      console.error('[Orquestrador] ⚠️ Erro ao registrar tokens (não crítico):', err);
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
      await supabaseAdmin.from('mensagens_temporarias').update({
        resposta: `ERRO: ${error.message}`
      }).eq('id', mensagem_id).catch(()=>{});
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
