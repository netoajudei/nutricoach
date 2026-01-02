/**
 * @name atualizar_medidas_corporais
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-06
 *
 * @description
 * 1. Recebe 'botao_id' e 'confirmado' (true/false) do webhook-wame.
 * 2. Busca 'botoes_ativos' para obter tool_call_id, aluno_id e argumentos (novas medidas).
 * 3. Se 'confirmado' for TRUE:
 * - Busca o último registro em 'body_metrics'.
 * - Cria um NOVO registro, copiando os dados antigos.
 * - Sobrescreve os dados antigos com os argumentos novos (incluindo o 'medidas_json').
 * - Busca 'altura_cm' de 'saude_e_rotina' se for o primeiro registro.
 * - Insere o novo registro em 'body_metrics'.
 * 4. Finaliza o tool call (OpenAI) e envia a resposta ao usuário.
 * 5. Limpa os bloqueios ('botoes_ativos' e 'alunos').
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const OPENAI_MODEL = Deno.env.get('OPENAI_MODEL') || 'gpt-4o-mini'; // Padrão alinhado
// ========================================
// HELPER: Finalizar Tool Call (Padrão v1.2)
// (Copiado da 'finalizar-registro-refeicao' bem-sucedida)
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
      respostaIA = outputParsed.message || (outputParsed.status === 'Sucesso' ? 'Ok, medidas registradas!' : 'Ok, cancelado!');
    }
    console.log(`[finalizarToolCall] 💬 Resposta da IA: ${respostaIA.substring(0, 100)}`);
    // Enviar a resposta da IA para o usuário
    console.log(`[finalizarToolCall] 📱 Enviando mensagem para o usuário...`);
    await supabase.functions.invoke('enviar_menssagem_whatsapp_oficial', {
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
  let botao_id = null;
  let aluno_id_para_limpeza = null;
  try {
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Receber payload do Webhook-WAME
    const body = await req.json();
    botao_id = body.botao_id;
    const { confirmado } = body;
    if (!botao_id) {
      throw new Error('Payload incompleto. "botao_id" é obrigatório.');
    }
    console.log(`[atualizar_medidas_corporais] 🚀 Processando botão: ${botao_id} | Confirmado: ${confirmado}`);
    // 2. Buscar dados do botão ativo
    console.log(`[atualizar_medidas_corporais] 🔍 Buscando dados do botão no DB...`);
    const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('aluno_id, conversation_id, tool_call_id, argumentos').eq('id', botao_id).single();
    if (botaoErr || !botao) {
      console.warn(`[atualizar_medidas_corporais] ⚠️ Botão ${botao_id} não encontrado. Pode já ter sido processado.`);
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
    const { conversation_id, tool_call_id, aluno_id, argumentos: args } = botao;
    aluno_id_para_limpeza = aluno_id;
    let outputJsonString = "";
    let mensagemEnviada = "";
    // 3. Lógica de Confirmação (Bifurcação)
    if (confirmado === true) {
      // ========================================
      // AÇÃO: Confirmar (Sim)
      // ========================================
      console.log(`[atualizar_medidas_corporais] ✅ Confirmado. Buscando último registro de medidas...`);
      // 3a. Buscar o último registro (como o usuário fez)
      const { data: ultimoRegistro, error: fetchError } = await supabase.from('body_metrics').select('*').eq('aluno_id', aluno_id).order('data_medicao', {
        ascending: false
      }).order('created_at', {
        ascending: false
      }).limit(1).maybeSingle(); // .maybeSingle() retorna null se não achar, em vez de erro
      if (fetchError) {
        throw new Error(`Erro ao buscar último registro: ${fetchError.message}`);
      }
      console.log(`[atualizar_medidas_corporais] 📄 Último registro encontrado: ${ultimoRegistro?.id || 'Nenhum'}`);
      // 3b. Preparar o NOVO registro 'medidas_json' (copiando o antigo e sobrescrevendo)
      const novo_medidas_json = {
        ...ultimoRegistro?.medidas_json || {}
      };
      if (args.braco_dir > 0) novo_medidas_json.braco_dir = args.braco_dir;
      if (args.braco_esq > 0) novo_medidas_json.braco_esq = args.braco_esq;
      if (args.coxa_dir > 0) novo_medidas_json.coxa_dir = args.coxa_dir;
      if (args.coxa_esq > 0) novo_medidas_json.coxa_esq = args.coxa_esq;
      if (args.panturrilha_dir > 0) novo_medidas_json.panturrilha_dir = args.panturrilha_dir;
      if (args.panturrilha_esq > 0) novo_medidas_json.panturrilha_esq = args.panturrilha_esq;
      // 3c. Lógica da altura_cm (CRÍTICO para constraint NOT NULL)
      let altura_para_inserir = ultimoRegistro?.altura_cm;
      if (!altura_para_inserir) {
        console.log(`[atualizar_medidas_corporais] ⚠️ Primeira medição. Buscando altura em 'saude_e_rotina'...`);
        const { data: saudeData } = await supabase.from('saude_e_rotina').select('altura_cm').eq('aluno_id', aluno_id).single();
        if (saudeData?.altura_cm) {
          altura_para_inserir = saudeData.altura_cm;
        } else {
          // Fallback final (embora não devesse acontecer no fluxo normal)
          altura_para_inserir = 1.0; // Evita falha de NOT NULL
          console.warn(`[atualizar_medidas_corporais] ‼️ ALERTA: Altura não encontrada nem em body_metrics nem em saude_e_rotina.`);
        }
      }
      // 3d. Preparar o NOVO registro completo (copiando e sobrescrevendo)
      const novoRegistro = {
        // Copia tudo do registro antigo (se existir)
        ...ultimoRegistro,
        // Sobrescreve campos obrigatórios
        aluno_id: aluno_id,
        data_medicao: new Date().toLocaleDateString('en-CA', {
          timeZone: 'America/Sao_Paulo'
        }),
        altura_cm: altura_para_inserir,
        // Sobrescreve APENAS o que foi informado (valor > 0 ou é 'peso')
        peso_kg: args.peso,
        circunferencia_cintura_cm: args.cintura > 0 ? args.cintura : ultimoRegistro?.circunferencia_cintura_cm,
        circunferencia_quadril_cm: args.quadril > 0 ? args.quadril : ultimoRegistro?.circunferencia_quadril_cm,
        percentual_gordura: args.percentual_gordura > 0 ? args.percentual_gordura : ultimoRegistro?.percentual_gordura,
        circunferencia_peito_cm: args.peito > 0 ? args.peito : ultimoRegistro?.circunferencia_peito_cm,
        // Sobrescreve o JSON
        medidas_json: novo_medidas_json,
        // Zera campos que não devem ser copiados
        id: undefined,
        created_at: undefined
      };
      // 3e. Inserir o novo registro
      console.log(`[atualizar_medidas_corporais] 💾 Inserindo novo registro...`);
      const { error: insertError } = await supabase.from('body_metrics').insert(novoRegistro);
      if (insertError) {
        console.error(`[atualizar_medidas_corporais] ❌ Erro ao inserir: ${insertError.message}`);
        throw new Error(`Erro ao salvar novas medidas: ${insertError.message}`);
      }
      console.log(`[atualizar_medidas_corporais] ✅ Medidas inseridas no histórico.`);
      outputJsonString = JSON.stringify({
        status: "Sucesso",
        message: "Suas novas medidas foram registradas com sucesso!"
      });
    } else {
      // ========================================
      // AÇÃO: Cancelar (Não)
      // ========================================
      console.log(`[atualizar_medidas_corporais] ❌ Cancelado pelo usuário.`);
      outputJsonString = JSON.stringify({
        status: "Cancelado",
        message: "Ok, registro de medidas cancelado. Se precisar alterar algo, é só me dizer."
      });
    }
    // 4. Finalizar o Tool Call (enviar resposta para a IA e para o usuário)
    console.log(`[atualizar_medidas_corporais] 🤖 Finalizando tool call (Padrão v1.2)...`);
    mensagemEnviada = await finalizarToolCallEChamarWhatsApp(supabase, conversation_id, tool_call_id, outputJsonString, aluno_id);
    // 5. Limpar AMBOS os bloqueios
    console.log(`[atualizar_medidas_corporais] 🧹 Limpando bloqueio NOVO (botoes_ativos): ${botao_id}`);
    await supabase.from('botoes_ativos').delete().eq('id', botao_id);
    console.log(`[atualizar_medidas_corporais] 🧹 Limpando bloqueio ANTIGO (alunos.aguardando_confirmacao)...`);
    await supabase.from('alunos').update({
      aguardando_confirmacao: null
    }).eq('id', aluno_id);
    console.log(`[atualizar_medidas_corporais] ✅ Processo concluído com sucesso.`);
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
    console.error(`[atualizar_medidas_corporais] ❌ ERRO GERAL:`, error.message);
    // Tenta limpar os bloqueios mesmo se houver erro
    if (botao_id || aluno_id_para_limpeza) {
      const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      console.warn(`[atualizar_medidas_corporais] ⚠️ Tentando limpar bloqueios após erro...`);
      if (botao_id) {
        await supabase.from('botoes_ativos').delete().eq('id', botao_id);
      }
      if (aluno_id_para_limpeza) {
        await supabase.from('alunos').update({
          aguardando_confirmacao: null
        }).eq('id', aluno_id_para_limpeza);
      }
    }
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
