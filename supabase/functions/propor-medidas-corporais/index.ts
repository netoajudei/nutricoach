/**
 * @name propor-medidas-corporais
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-06
 *
 * @description
 * 1. Recebe o tool_call da IA (orquestrador) com as medidas corporais.
 * 2. Busca o WhatsApp do aluno.
 * 3. Cria (UPSERT) um registro na tabela `botoes_ativos` com todos os argumentos.
 * 4. Define a `edge_function` de resposta como 'atualizar_medidas_corporais'.
 * 5. Formata uma mensagem de confirmação (mostrando apenas medidas > 0).
 * 6. Envia o botão de confirmação (Sim/Não) para o aluno via WAME.
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type'
};
/**
 * Helper para construir a mensagem de confirmação de forma dinâmica.
 * Mostra apenas as medidas que foram de fato informadas (valor > 0).
 */ function construirMensagemMedidas(args) {
  let listaMedidas = `• Peso: ${args.peso} kg\n`; // Peso é sempre obrigatório
  // Mapeia as chaves dos argumentos para nomes legíveis
  const mapaMedidas = {
    cintura: "Cintura",
    quadril: "Quadril",
    peito: "Peito",
    percentual_gordura: "Gordura (%)",
    braco_dir: "Braço Dir.",
    braco_esq: "Braço Esq.",
    coxa_dir: "Coxa Dir.",
    coxa_esq: "Coxa Esq.",
    panturrilha_dir: "Panturrilha Dir.",
    panturrilha_esq: "Panturrilha Esq."
  };
  // Adiciona outras medidas apenas se elas forem maiores que 0
  for(const key in mapaMedidas){
    if (args[key] && args[key] > 0) {
      const nome = mapaMedidas[key];
      const unidade = key === 'percentual_gordura' ? '%' : 'cm';
      listaMedidas += `• ${nome}: ${args[key]} ${unidade}\n`;
    }
  }
  return `⚖️ Confirmar Medidas\n\nVocê me informou as seguintes medidas:\n\n${listaMedidas}\nConfirmar este registro?`;
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
  try {
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // 1. Receber payload do Orquestrador
    const body = await req.json();
    const { aluno_id, conversation_id, tool_call_id, argumentos } = body;
    console.log(`[propor-medidas-corporais] 🚀 Iniciando para aluno: ${aluno_id}`);
    console.log(`[propor-medidas-corporais] 🤖 Tool Call ID: ${tool_call_id}`);
    if (!aluno_id || !conversation_id || !tool_call_id || !argumentos) {
      throw new Error('Payload incompleto. Faltando aluno_id, conversation_id, tool_call_id ou argumentos.');
    }
    // 2. Argumentos já vêm como Objeto JSON
    const args = argumentos;
    if (args.peso === undefined) {
      throw new Error('Argumentos da IA incompletos. "peso" é obrigatório.');
    }
    // 3. Buscar dados do aluno (WhatsApp)
    console.log(`[propor-medidas-corporais] 🔍 Buscando WhatsApp do aluno...`);
    const { data: alunoData, error: alunoError } = await supabase.from('alunos').select('whatsapp').eq('id', aluno_id).single();
    if (alunoError) throw alunoError;
    if (!alunoData) throw new Error(`Aluno ${aluno_id} não encontrado.`);
    const whatsappNumber = alunoData.whatsapp;
    console.log(`[propor-medidas-corporais] ✅ WhatsApp: ${whatsappNumber}`);
    // 4. Criar (UPSERT) o registro em `botoes_ativos`
    console.log(`[propor-medidas-corporais] 💾 Criando registro em botoes_ativos...`);
    const { data: botaoData, error: botaoError } = await supabase.from('botoes_ativos').upsert({
      aluno_id: aluno_id,
      conversation_id: conversation_id,
      tool_call_id: tool_call_id,
      tipo_acao: 'medidas_corporais',
      argumentos: args,
      edge_function: 'atualizar_medidas_corporais' // A função que será chamada na confirmação
    }, {
      onConflict: 'aluno_id'
    }).select('id').single();
    if (botaoError) throw botaoError;
    const botao_id = botaoData.id;
    console.log(`[propor-medidas-corporais] ✅ Registro de botão criado/atualizado: ${botao_id}`);
    // 5. Preparar payloads de botão (padrão centralizado)
    const payloadSim = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: true
    });
    const payloadNao = JSON.stringify({
      action: 'resposta_botao',
      botao_id: botao_id,
      confirmado: false
    });
    // 6. Buscar API Key da WAME
    console.log(`[propor-medidas-corporais] 🔑 Buscando API Key...`);
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError) throw configError;
    const api_key = configData.valor;
    // 7. Construir a mensagem (usando o helper)
    const mensagemTexto = construirMensagemMedidas(args);
    console.log(`[propor-medidas-corporais] 💬 Mensagem formatada:\n${mensagemTexto}`);
    const requestBody = {
      to: whatsappNumber,
      header: {
        title: '⚖️ Registro de Medidas'
      },
      text: mensagemTexto,
      footer: 'Escolha uma opção:',
      buttons: [
        {
          type: 'quick_reply',
          id: payloadSim,
          text: 'Sim, registrar!'
        },
        {
          type: 'quick_reply',
          id: payloadNao,
          text: 'Não, alterar'
        }
      ]
    };
    // 8. Enviar o botão para o WAME
    console.log(`[propor-medidas-corporais] 📤 Enviando botão para WAME...`);
    const wameResponse = await fetch(`https://us.api-wa.me/${api_key}/message/button_reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(requestBody)
    });
    if (!wameResponse.ok) {
      const errorBody = await wameResponse.text();
      throw new Error(`Erro ao enviar mensagem WAME: ${wameResponse.status} - ${errorBody}`);
    }
    console.log(`[propor-medidas-corporais] ✅ Proposta de medidas enviada com sucesso.`);
    // 9. Retornar OK para o Orquestrador
    return new Response(JSON.stringify({
      success: true,
      message: "Proposta de medidas enviada ao usuário."
    }), {
      status: 200,
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error(`[propor-medidas-corporais] ❌ ERRO:`, error.message);
    console.error(`[propor-medidas-corporais] Stack:`, error.stack);
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
