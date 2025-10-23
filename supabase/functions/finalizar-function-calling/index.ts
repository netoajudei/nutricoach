/**
 * @name finalizar-function-calling
 * @version 1.0.0
 * @description
 * Função que resolve o problema de function calling na API Responses
 * quando o endpoint de tool_outputs ainda não está disponível.
 * 
 * Estratégia:
 * 1. Busca o histórico completo da conversation via GET /conversations/{id}/items
 * 2. Envia o histórico para LLM resumir o contexto de forma inteligente
 * 3. Retorna o resumo para ser usado na criação de uma nova conversation
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
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
  try {
    const body = await req.json();
    const { conversation_id, tool_result_message } = body;
    console.log(`[Finalizador] 📥 Recebido: conversation_id=${conversation_id}`);
    // Validações
    if (!conversation_id) {
      throw new Error("O 'conversation_id' é obrigatório.");
    }
    if (!conversation_id.startsWith('conv_')) {
      throw new Error(`conversation_id inválida (formato esperado: conv_XXX): ${conversation_id}`);
    }
    console.log(`[Finalizador] 🔄 Processando conversation: ${conversation_id}`);
    // ============================================
    // ETAPA 1: Buscar histórico da conversation
    // ============================================
    console.log('[Finalizador] 📥 Buscando histórico da conversation...');
    const conversationUrl = `https://api.openai.com/v1/conversations/${conversation_id}/items?limit=50`;
    console.log(`[Finalizador] 🔗 URL: ${conversationUrl}`);
    const historyResponse = await fetch(conversationUrl, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      }
    });
    console.log(`[Finalizador] 📊 Status da busca: ${historyResponse.status}`);
    if (!historyResponse.ok) {
      const errorText = await historyResponse.text();
      console.error(`[Finalizador] ❌ Erro ao buscar histórico:`, errorText);
      throw new Error(`Erro ao buscar histórico (${historyResponse.status}): ${errorText}`);
    }
    const historyData = await historyResponse.json();
    console.log(`[Finalizador] ✅ Histórico obtido: ${historyData.data?.length || 0} mensagens`);
    // ============================================
    // ETAPA 2: Formatar histórico para resumo
    // ============================================
    console.log('[Finalizador] 📝 Formatando histórico...');
    let historicoFormatado = '';
    for (const item of historyData.data.reverse()){
      const role = item.role === 'user' ? 'ALUNO' : 'ASSISTENTE';
      // Verificar se content existe e é um array
      if (!item.content || !Array.isArray(item.content)) {
        console.log(`[Finalizador] ⚠️ Item sem content ou content não é array:`, item);
        continue;
      }
      for (const content of item.content){
        if (!content || !content.type) {
          console.log(`[Finalizador] ⚠️ Content inválido:`, content);
          continue;
        }
        if (content.type === 'input_text' || content.type === 'output_text') {
          historicoFormatado += `\n[${role}]: ${content.text || ''}\n`;
        } else if (content.type === 'function_call') {
          historicoFormatado += `\n[TOOL CHAMADA]: ${content.name || 'desconhecida'}\n`;
          if (content.arguments) {
            historicoFormatado += `Argumentos: ${content.arguments}\n`;
          }
        }
      }
    }
    // Adicionar o resultado da tool ao histórico
    if (tool_result_message) {
      historicoFormatado += `\n[TOOL RESULTADO]: ${tool_result_message}\n`;
    }
    if (!historicoFormatado || historicoFormatado.trim().length === 0) {
      console.log('[Finalizador] ⚠️ Histórico vazio após formatação');
      historicoFormatado = '[Conversa iniciada]';
    }
    console.log('[Finalizador] 📊 Histórico formatado:');
    console.log(historicoFormatado.substring(0, 500) + '...');
    // ============================================
    // ETAPA 3: Resumir histórico com LLM
    // ============================================
    console.log('[Finalizador] 🤖 Enviando para LLM resumir...');
    const promptResumo = `Você é o encarregado de resumir o histórico de conversa de um aplicativo de coaching nutricional e fitness.

Você receberá um histórico de conversação que precisou ser resumido para a criação de uma nova conversation (devido a limitações técnicas da API).

INSTRUÇÕES CRÍTICAS:

1. **Organize de forma clara e estruturada** todos os dados sensíveis mencionados
2. **Seja resumido mas completo** - uma LLM deve ter noção de TUDO que foi discutido
3. **Diferencie intenções de ações confirmadas**:
   - ❌ "O aluno perguntou o que comer no café" ≠ O aluno comeu
   - ✅ "O aluno registrou o consumo de X no café da manhã" = Ação confirmada
   
4. **Identifique e marque claramente**:
   - 📊 Registros alimentares CONFIRMADOS (refeições que foram consumidas)
   - 💪 Exercícios EXECUTADOS (não apenas planejados)
   - ❓ Dúvidas e questionamentos do aluno
   - 💡 Orientações dadas pelo assistente
   - 🎯 Metas e objetivos mencionados
   - ⚠️ Problemas relatados (ex: desconforto, dores, etc)

5. **Mantenha valores numéricos exatos**: calorias, macros, pesos, repetições
6. **Preserve o contexto temporal**: "hoje", "ontem", datas específicas
7. **Inclua o resultado de tools executadas** se houver

FORMATO DE SAÍDA:

Resumo da conversa do coaching nutricional:

[Organize em tópicos claros com os dados relevantes]

---

HISTÓRICO A SER RESUMIDO:
${historicoFormatado}
`;
    const resumoResponse = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        model: 'gpt-4.1-mini',
        messages: [
          {
            role: 'user',
            content: promptResumo
          }
        ],
        temperature: 0.3,
        max_tokens: 2000
      })
    });
    if (!resumoResponse.ok) {
      const errorText = await resumoResponse.text();
      throw new Error(`Erro ao gerar resumo: ${errorText}`);
    }
    const resumoData = await resumoResponse.json();
    const resumo = resumoData.choices[0].message.content;
    console.log('[Finalizador] ✅ Resumo gerado com sucesso');
    console.log('[Finalizador] 📄 Preview do resumo:');
    console.log(resumo.substring(0, 300) + '...');
    // ============================================
    // ETAPA 4: Criar nova conversation
    // ============================================
    console.log('[Finalizador] 🆕 Criando nova conversation...');
    const createConvResponse = await fetch('https://api.openai.com/v1/conversations', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        metadata: {
          tipo: 'coaching_nutricional',
          migrada_de: conversation_id
        }
      })
    });
    if (!createConvResponse.ok) {
      const errorText = await createConvResponse.text();
      throw new Error(`Erro ao criar conversation: ${errorText}`);
    }
    const newConvData = await createConvResponse.json();
    const novo_conversation_id = newConvData.id;
    console.log(`[Finalizador] ✅ Nova conversation criada: ${novo_conversation_id}`);
    // ============================================
    // ETAPA 5: Inserir resumo na nova conversation
    // ============================================
    console.log('[Finalizador] 📝 Inserindo resumo na nova conversation...');
    const insertResumoResponse = await fetch(`https://api.openai.com/v1/conversations/${novo_conversation_id}/items`, {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        items: [
          {
            type: 'message',
            role: 'user',
            content: [
              {
                type: 'input_text',
                text: resumo
              }
            ]
          },
          {
            type: 'message',
            role: 'assistant',
            content: [
              {
                type: 'output_text',
                text: 'ok entendido'
              }
            ]
          }
        ]
      })
    });
    if (!insertResumoResponse.ok) {
      const errorText = await insertResumoResponse.text();
      throw new Error(`Erro ao inserir resumo: ${errorText}`);
    }
    const insertResumoData = await insertResumoResponse.json();
    console.log('[Finalizador] ✅ Resumo inserido na conversation');
    console.log(`[Finalizador] 📊 Items inseridos: ${insertResumoData.data?.length || 0}`);
    // ============================================
    // ETAPA 6: Retornar novo conversation_id
    // ============================================
    return new Response(JSON.stringify({
      success: true,
      novo_conversation_id: novo_conversation_id,
      conversation_id_antiga: conversation_id,
      resumo: resumo,
      mensagens_processadas: historyData.data.length,
      tokens_resumo: {
        input: resumoData.usage.prompt_tokens,
        output: resumoData.usage.completion_tokens,
        total: resumoData.usage.total_tokens
      }
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[Finalizador] ❌ ERRO:', error.message);
    console.error('[Finalizador] 📋 Stack:', error.stack);
    console.error('[Finalizador] 📋 Error completo:', JSON.stringify(error, null, 2));
    return new Response(JSON.stringify({
      success: false,
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
