/**
 * @name iniciar-plano-de-treino
 * @version 4.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-09
 *
 * @description
 * Edge Function (Orquestrador da ETAPA 1 - Criação de Plano de Treino)
 * 
 * CORREÇÃO CRÍTICA (v4.0.0):
 * - Corrigido formato da API v1/responses: 'input_text' em vez de 'output_text'
 * - Sistema de loop com 3 retentativas
 * - Logs detalhados em cada etapa
 * - Validação robusta dos argumentos
 *
 * @workflow
 * 1. Recebe: { aluno_id, input_texto }
 * 2. Busca prompt do banco (tabela prompts_sistema)
 * 3. Loop de até 3 tentativas com OpenAI
 * 4. Valida argumentos retornados pela IA
 * 5. Chama RPC iniciar_novo_plano_de_treino
 * 6. Retorna IDs dos treinos criados
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
// ============================================
// CONFIGURAÇÕES
// ============================================
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS"
};
const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
const OPENAI_API_KEY = Deno.env.get("OPENAI_API_KEY");
const OPENAI_MODEL = Deno.env.get("OPENAI_MODEL") || "gpt-4.1";
// ============================================
// HELPER: Resposta JSON
// ============================================
function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders
    }
  });
}
// ============================================
// VALIDADOR DE ARGUMENTOS
// ============================================
function validarArgumentosEtapa1(args) {
  console.log('[VALIDADOR] 🔍 Iniciando validação dos argumentos...');
  if (!args) {
    console.log('[VALIDADOR] ❌ Argumentos são null/undefined');
    return false;
  }
  const { nome, objetivo, frequencia_semanal_dias, programas_de_treino } = args;
  // Validação 1: Campos obrigatórios
  if (!nome) {
    console.log('[VALIDADOR] ❌ Campo "nome" ausente');
    return false;
  }
  if (!objetivo) {
    console.log('[VALIDADOR] ❌ Campo "objetivo" ausente');
    return false;
  }
  if (!frequencia_semanal_dias) {
    console.log('[VALIDADOR] ❌ Campo "frequencia_semanal_dias" ausente');
    return false;
  }
  if (!programas_de_treino) {
    console.log('[VALIDADOR] ❌ Campo "programas_de_treino" ausente');
    return false;
  }
  // Validação 2: Array não vazio
  if (!Array.isArray(programas_de_treino)) {
    console.log('[VALIDADOR] ❌ "programas_de_treino" não é um array');
    return false;
  }
  if (programas_de_treino.length === 0) {
    console.log('[VALIDADOR] ❌ "programas_de_treino" está vazio');
    return false;
  }
  // Validação 3: Primeiro programa tem os campos necessários
  const primeiroPrograma = programas_de_treino[0];
  if (!primeiroPrograma.nome_programa) {
    console.log('[VALIDADOR] ❌ Primeiro programa sem "nome_programa"');
    return false;
  }
  if (!primeiroPrograma.dia_da_semana) {
    console.log('[VALIDADOR] ❌ Primeiro programa sem "dia_da_semana"');
    return false;
  }
  console.log('[VALIDADOR] ✅ Argumentos válidos!');
  console.log(`[VALIDADOR] 📊 Nome: "${nome}"`);
  console.log(`[VALIDADOR] 📊 Objetivo: "${objetivo}"`);
  console.log(`[VALIDADOR] 📊 Frequência: ${frequencia_semanal_dias} dias/semana`);
  console.log(`[VALIDADOR] 📊 Programas: ${programas_de_treino.length} treinos na semana`);
  return true;
}
// ============================================
// HANDLER PRINCIPAL
// ============================================
serve(async (req)=>{
  // Tratamento de CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: corsHeaders
    });
  }
  const startedAt = new Date().toISOString();
  console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  console.log('[INICIAR-PLANO v4.0] 🚀 INÍCIO DA EXECUÇÃO');
  console.log(`[INICIAR-PLANO v4.0] ⏰ Timestamp: ${startedAt}`);
  console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
  try {
    // ============================================
    // ETAPA 0: VALIDAÇÃO DE AMBIENTE
    // ============================================
    console.log('[ETAPA 0] 🔐 Validando variáveis de ambiente...');
    if (!SUPABASE_URL || !SERVICE_ROLE || !OPENAI_API_KEY) {
      throw new Error("❌ Variáveis de ambiente ausentes (SUPABASE_URL, SERVICE_ROLE_KEY ou OPENAI_API_KEY)");
    }
    console.log('[ETAPA 0] ✅ Supabase URL: ' + SUPABASE_URL.substring(0, 30) + '...');
    console.log('[ETAPA 0] ✅ OpenAI Model: ' + OPENAI_MODEL);
    console.log('[ETAPA 0] ✅ Service Role: Presente\n');
    // ============================================
    // ETAPA 1: PARSE DO PAYLOAD
    // ============================================
    console.log('[ETAPA 1] 📥 Fazendo parse do payload...');
    const body = await req.json().catch(()=>({}));
    const { aluno_id, input_texto } = body;
    if (!aluno_id || !input_texto) {
      throw new Error("❌ Payload incompleto. Necessário: aluno_id e input_texto");
    }
    console.log(`[ETAPA 1] ✅ Aluno ID: ${aluno_id}`);
    console.log(`[ETAPA 1] ✅ Input (${input_texto.length} chars): "${input_texto.substring(0, 100)}..."\n`);
    // ============================================
    // ETAPA 2: CONEXÃO SUPABASE
    // ============================================
    console.log('[ETAPA 2] 🔌 Criando cliente Supabase...');
    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE, {
      auth: {
        persistSession: false
      }
    });
    console.log('[ETAPA 2] ✅ Cliente Supabase criado\n');
    // ============================================
    // ETAPA 3: BUSCAR PROMPT DO BANCO
    // ============================================
    const CHAVE_PROMPT = 'criar_programas_treino';
    console.log(`[ETAPA 3] 🔍 Buscando prompt: "${CHAVE_PROMPT}"...`);
    const { data: promptData, error: promptErr } = await supabase.from("prompts_sistema").select("prompt_base, functions_jsonb").eq("chave", CHAVE_PROMPT).single();
    if (promptErr) {
      throw new Error(`❌ Erro ao buscar prompt: ${promptErr.message}`);
    }
    if (!promptData) {
      throw new Error(`❌ Prompt "${CHAVE_PROMPT}" não encontrado na tabela prompts_sistema`);
    }
    const { prompt_base, functions_jsonb } = promptData;
    if (!prompt_base || !functions_jsonb) {
      throw new Error(`❌ Prompt "${CHAVE_PROMPT}" mal configurado (prompt_base ou functions_jsonb nulos)`);
    }
    console.log(`[ETAPA 3] ✅ Prompt encontrado (${prompt_base.length} chars)`);
    console.log(`[ETAPA 3] ✅ Functions: ${functions_jsonb.length} ferramenta(s) disponível(is)\n`);
    // ============================================
    // ETAPA 4: INICIALIZAR HISTÓRICO DE CONVERSA
    // ============================================
    console.log('[ETAPA 4] 📝 Inicializando histórico de conversa...');
    console.log('[ETAPA 4] 🔧 Formato: API v1/responses (input_text)');
    // ✅ FORMATO CORRETO DA API
    let conversation_history = [
      {
        type: "message",
        role: "system",
        content: [
          {
            type: "input_text",
            text: prompt_base
          }
        ]
      },
      {
        type: "message",
        role: "user",
        content: [
          {
            type: "input_text",
            text: input_texto
          }
        ]
      }
    ];
    console.log('[ETAPA 4] ✅ Histórico inicializado com 2 mensagens\n');
    // ============================================
    // ETAPA 5: LOOP DE TENTATIVAS (3x)
    // ============================================
    const MAX_TENTATIVAS = 3;
    let last_conversation_id = null;
    let last_tool_call_id = null;
    let argumentos_validos = null;
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('[ETAPA 5] 🔄 INICIANDO LOOP DE TENTATIVAS');
    console.log(`[ETAPA 5] 📊 Máximo: ${MAX_TENTATIVAS} tentativas`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    for(let tentativa = 1; tentativa <= MAX_TENTATIVAS; tentativa++){
      console.log(`\n╔═══════════════════════════════════════════╗`);
      console.log(`║  🤖 TENTATIVA ${tentativa}/${MAX_TENTATIVAS}                        ║`);
      console.log(`╚═══════════════════════════════════════════╝\n`);
      // ============================================
      // 5.1: PREPARAR PAYLOAD OPENAI
      // ============================================
      console.log(`[TENTATIVA ${tentativa}] 📦 Preparando payload OpenAI...`);
      const openaiPayload = {
        model: OPENAI_MODEL,
        input: conversation_history,
        tools: functions_jsonb,
        tool_choice: "required",
        store: true
      };
      // Se já existe conversation_id, adiciona ao payload
      if (last_conversation_id) {
        openaiPayload.conversation = last_conversation_id;
        console.log(`[TENTATIVA ${tentativa}] 🔗 Usando conversation existente: ${last_conversation_id}`);
      }
      console.log(`[TENTATIVA ${tentativa}] 📊 Mensagens no histórico: ${conversation_history.length}`);
      // ============================================
      // 5.2: CHAMAR OPENAI
      // ============================================
      console.log(`[TENTATIVA ${tentativa}] 🌐 Chamando API OpenAI...`);
      console.log(`[TENTATIVA ${tentativa}] 📍 Endpoint: https://api.openai.com/v1/responses`);
      const openaiResponse = await fetch('https://api.openai.com/v1/responses', {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${OPENAI_API_KEY}`,
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(openaiPayload)
      });
      // ============================================
      // 5.3: VERIFICAR RESPOSTA HTTP
      // ============================================
      if (!openaiResponse.ok) {
        const errorText = await openaiResponse.text();
        console.error(`[TENTATIVA ${tentativa}] ❌ Erro HTTP ${openaiResponse.status}`);
        console.error(`[TENTATIVA ${tentativa}] 💥 Detalhes: ${errorText}`);
        throw new Error(`Erro OpenAI (HTTP ${openaiResponse.status}): ${errorText}`);
      }
      const responseData = await openaiResponse.json();
      last_conversation_id = responseData.conversation_id;
      console.log(`[TENTATIVA ${tentativa}] ✅ Resposta recebida!`);
      console.log(`[TENTATIVA ${tentativa}] 🆔 Response ID: ${responseData.id}`);
      console.log(`[TENTATIVA ${tentativa}] 🆔 Conversation ID: ${last_conversation_id}`);
      console.log(`[TENTATIVA ${tentativa}] 📊 Input tokens: ${responseData.usage?.input_tokens ?? 'N/A'}`);
      console.log(`[TENTATIVA ${tentativa}] 📊 Output tokens: ${responseData.usage?.output_tokens ?? 'N/A'}`);
      // ============================================
      // 5.4: EXTRAIR OUTPUT
      // ============================================
      const output = responseData.output?.[0];
      if (!output) {
        console.warn(`[TENTATIVA ${tentativa}] ⚠️ Resposta sem output definido`);
        continue;
      }
      console.log(`[TENTATIVA ${tentativa}] 📤 Output type: ${output.type}`);
      // ============================================
      // 5.5: VERIFICAR SE É FUNCTION CALL
      // ============================================
      if (output?.type === 'function_call') {
        console.log(`[TENTATIVA ${tentativa}] 🎯 Function call detectada!`);
        console.log(`[TENTATIVA ${tentativa}] 🔧 Função: ${output.name}`);
        console.log(`[TENTATIVA ${tentativa}] 🆔 Call ID: ${output.call_id}`);
        // Parse dos argumentos
        let tool_args;
        try {
          tool_args = JSON.parse(output.arguments || "{}");
          console.log(`[TENTATIVA ${tentativa}] 📥 Argumentos parseados com sucesso`);
        } catch (parseError) {
          console.error(`[TENTATIVA ${tentativa}] ❌ Erro ao parsear argumentos:`, parseError);
          tool_args = {};
        }
        // ============================================
        // 🔍 IMPRESSÃO DETALHADA DOS ARGUMENTOS
        // ============================================
        console.log('\n╔═══════════════════════════════════════════╗');
        console.log('║  📋 ARGUMENTOS EXTRAÍDOS DA FUNÇÃO       ║');
        console.log('╚═══════════════════════════════════════════╝');
        console.log(JSON.stringify(tool_args, null, 2));
        console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
        // ============================================
        // 5.6: VALIDAR ARGUMENTOS
        // ============================================
        if (validarArgumentosEtapa1(tool_args)) {
          // ✅ SUCESSO!
          console.log(`\n╔═══════════════════════════════════════════╗`);
          console.log(`║  ✅ SUCESSO NA TENTATIVA ${tentativa}                ║`);
          console.log(`╚═══════════════════════════════════════════╝\n`);
          last_tool_call_id = output.call_id;
          argumentos_validos = tool_args;
          break; // Sai do loop
        } else {
          // ❌ Argumentos inválidos
          console.warn(`[TENTATIVA ${tentativa}] ⚠️ Argumentos inválidos ou incompletos`);
          console.warn(`[TENTATIVA ${tentativa}] 🔄 Adicionando feedback ao histórico...\n`);
          conversation_history.push(output, {
            type: "message",
            role: "user",
            content: [
              {
                type: "input_text",
                text: "Você acionou a ferramenta, porém os argumentos vieram vazios ou incompletos. Por favor, releia o texto original e extraia TODAS as informações necessárias: nome do programa, objetivo, frequencia_semanal_dias e programas_de_treino com nome_programa e dia_da_semana para cada treino."
              }
            ]
          });
        }
      } else {
        // ❌ IA não chamou a ferramenta
        console.warn(`[TENTATIVA ${tentativa}] ⚠️ IA não chamou a ferramenta (type: ${output.type})`);
        console.warn(`[TENTATIVA ${tentativa}] 🔄 Adicionando orientação ao histórico...\n`);
        conversation_history.push(output, {
          type: "message",
          role: "user",
          content: [
            {
              type: "input_text",
              text: "Você precisa analisar o texto do usuário e extrair os parâmetros através do function calling. Por favor, use a ferramenta 'iniciar_novo_plano_de_treino' com TODOS os parâmetros necessários."
            }
          ]
        });
      }
    } // FIM DO LOOP
    // ============================================
    // ETAPA 6: VERIFICAR SE LOOP FALHOU
    // ============================================
    console.log('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('[ETAPA 6] 🎯 VERIFICANDO RESULTADO DO LOOP');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    if (!argumentos_validos) {
      console.error('[ETAPA 6] ❌ FALHA TOTAL');
      console.error('[ETAPA 6] 💥 IA não retornou argumentos válidos após 3 tentativas');
      throw new Error("Falha na Etapa 1: A IA não conseguiu gerar os parâmetros do plano de treino após 3 tentativas. Por favor, revise o texto de entrada ou o prompt do sistema.");
    }
    console.log('[ETAPA 6] ✅ Argumentos válidos obtidos!\n');
    // ============================================
    // ETAPA 7: CHAMAR RPC DO BANCO
    // ============================================
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('[ETAPA 7] 🛠️  CHAMANDO RPC DO BANCO');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    const { nome, objetivo, frequencia_semanal_dias, programas_de_treino } = argumentos_validos;
    console.log('[ETAPA 7] 📞 Invocando: iniciar_novo_plano_de_treino');
    console.log('[ETAPA 7] 📊 Parâmetros:');
    console.log(`[ETAPA 7]   - aluno_id: ${aluno_id}`);
    console.log(`[ETAPA 7]   - nome: "${nome}"`);
    console.log(`[ETAPA 7]   - objetivo: "${objetivo}"`);
    console.log(`[ETAPA 7]   - frequencia: ${frequencia_semanal_dias}`);
    console.log(`[ETAPA 7]   - programas: ${programas_de_treino.length} treino(s)\n`);
    const { data: rpcData, error: rpcError } = await supabase.rpc("iniciar_novo_plano_de_treino", {
      p_aluno_id: aluno_id,
      p_nome_programa: nome,
      p_objetivo: objetivo,
      p_frequencia: frequencia_semanal_dias,
      p_programas_json: programas_de_treino
    });
    if (rpcError) {
      console.error('[ETAPA 7] ❌ Erro na RPC');
      console.error('[ETAPA 7] 💥 Detalhes:', rpcError);
      throw new Error(`Falha ao salvar plano no banco: ${rpcError.message}`);
    }
    console.log('[ETAPA 7] ✅ RPC executada com sucesso!');
    console.log(`[ETAPA 7] 📊 Registros criados: ${rpcData?.length ?? 0} treino(s) da semana\n`);
    // ============================================
    // ETAPA 7.1: CHAMAR SEGUNDA FUNÇÃO
    // ============================================
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('[ETAPA 7.1] 🔗 ACIONANDO criar-exercicios-treino');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    console.log('[ETAPA 7.1] 📤 Enviando programas_criados para segunda função...');
    const { error: exerciciosError } = await supabase.functions.invoke('criar-exercicios-treino', {
      body: {
        programas_criados: rpcData,
        input_texto: input_texto
      }
    });
    if (exerciciosError) {
      console.error('[ETAPA 7.1] ❌ Erro ao criar exercícios:', exerciciosError);
      throw new Error(`Falha ao criar exercícios: ${exerciciosError.message}`);
    }
    console.log('[ETAPA 7.1] ✅ Exercícios criados com sucesso!\n');
    // ============================================
    // ETAPA 8: PREPARAR RESPOSTA FINAL
    // ============================================
    const finishedAt = new Date().toISOString();
    const duracao = new Date(finishedAt).getTime() - new Date(startedAt).getTime();
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('[ETAPA 8] 🎉 CONCLUSÃO COM SUCESSO');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log(`[ETAPA 8] ⏰ Início: ${startedAt}`);
    console.log(`[ETAPA 8] ⏰ Fim: ${finishedAt}`);
    console.log(`[ETAPA 8] ⏱️  Duração: ${duracao}ms`);
    console.log(`[ETAPA 8] 🎯 Conversation ID: ${last_conversation_id}`);
    console.log(`[ETAPA 8] 🎯 Tool Call ID: ${last_tool_call_id}`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    return jsonResponse({
      success: true,
      message: "Etapa 1 (Início do Plano de Treino) concluída com sucesso!",
      data: {
        conversation_id: last_conversation_id,
        tool_call_id: last_tool_call_id,
        programas_criados: rpcData,
        argumentos_extraidos: argumentos_validos
      },
      timing: {
        started_at: startedAt,
        finished_at: finishedAt,
        duration_ms: duracao
      }
    });
  } catch (error) {
    // ============================================
    // 💥 SUPER-CATCH (TRATAMENTO DE ERROS)
    // ============================================
    const finishedAt = new Date().toISOString();
    console.error('\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.error('[SUPER-CATCH] 💥 ERRO CRÍTICO');
    console.error('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.error('[SUPER-CATCH] ❌ Mensagem:', error.message);
    console.error('[SUPER-CATCH] 📚 Stack:', error.stack);
    console.error('[SUPER-CATCH] ⏰ Falha em:', finishedAt);
    console.error('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');
    return jsonResponse({
      error: String(error?.message ?? error),
      stack: error?.stack,
      instrucao: "Falha na Etapa 1 (iniciar-plano-de-treino). Verifique os logs acima para mais detalhes.",
      timing: {
        started_at: startedAt,
        failed_at: finishedAt
      }
    }, 500);
  }
});
