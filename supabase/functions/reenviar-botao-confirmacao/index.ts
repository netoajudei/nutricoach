/**
 * @name reenviar-botao-confirmacao
 * @version 1.0.0
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 01:25:00 -03:00
 * 
 * @description
 * Edge Function que reenvia o botão de confirmação quando o usuário
 * tenta enviar uma mensagem enquanto está com um registro pendente.
 * Implementa o "bloqueio educado" reapresentando as opções ao usuário.
 * 
 * @workflow
 * 1. Recebe aluno_id e whatsapp
 * 2. Busca aguardando_confirmacao do aluno no banco
 * 3. Valida que existe pendência
 * 4. Extrai button_payload_sim e button_payload_nao salvos
 * 5. Reenvia botão via WAME API com mensagem educada
 * 6. Retorna sucesso
 * 
 * @usage
 * Acionada pelo webhook quando:
 * - aguardando_confirmacao.aguardando === true
 * - Usuário envia mensagem de texto (não é botão)
 * 
 * @param {string} aluno_id - ID do aluno
 * @param {string} whatsapp - Número WhatsApp do aluno
 * 
 * @returns {object} { success, message, resubmitted }
 * 
 * @security
 * - Usa SUPABASE_SERVICE_ROLE_KEY
 * - API key WAME buscada de config_sistema
 * 
 * @dependencies
 * - WAME API (button_reply endpoint)
 * - Tabelas: alunos, config_sistema
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
  try {
    console.log('[REENVIAR BOTÃO] 🔄 Iniciando');
    const { aluno_id, whatsapp } = await req.json();
    if (!aluno_id || !whatsapp) {
      throw new Error('Parâmetros obrigatórios faltando: aluno_id, whatsapp');
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ============================================
    // 1. BUSCAR AGUARDANDO_CONFIRMACAO DO ALUNO
    // ============================================
    console.log('[REENVIAR BOTÃO] 🔍 Buscando pendência do aluno...');
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('aguardando_confirmacao').eq('id', aluno_id).single();
    if (alunoError || !aluno) {
      throw new Error('Aluno não encontrado');
    }
    const aguardando = aluno.aguardando_confirmacao;
    if (!aguardando || !aguardando.aguardando) {
      console.warn('[REENVIAR BOTÃO] ⚠️ Nenhuma pendência encontrada');
      return new Response(JSON.stringify({
        success: true,
        message: 'Nenhuma pendência encontrada',
        resubmitted: false
      }), {
        headers: {
          ...corsHeaders,
          'Content-Type': 'application/json'
        },
        status: 200
      });
    }
    console.log('[REENVIAR BOTÃO] ✅ Pendência encontrada');
    console.log('[REENVIAR BOTÃO] 📋 Conversation ID:', aguardando.conversation_id);
    // ============================================
    // 2. EXTRAIR PAYLOADS DOS BOTÕES
    // ============================================
    const button_payload_sim = aguardando.button_payload_sim;
    const button_payload_nao = aguardando.button_payload_nao;
    if (!button_payload_sim || !button_payload_nao) {
      throw new Error('Payloads dos botões não encontrados');
    }
    console.log('[REENVIAR BOTÃO] ✅ Payloads extraídos');
    // ============================================
    // 3. BUSCAR API KEY
    // ============================================
    const { data: configData, error: configError } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (configError || !configData) {
      throw new Error('WAME_API_KEY não encontrada');
    }
    const api_key = configData.valor;
    // ============================================
    // 4. MONTAR MENSAGEM EDUCADA
    // ============================================
    const mensagem_texto = `⏸️ **Para continuar nossa conversa, preciso que você confirme o registro abaixo primeiro!**

Escolha uma das opções:`;
    // ============================================
    // 5. REENVIAR BOTÃO VIA WAME
    // ============================================
    const api_url = `https://us.api-wa.me/${api_key}/message/button_reply`;
    const request_body = {
      to: whatsapp,
      header: {
        title: '⏸️ Aguardando Confirmação'
      },
      text: mensagem_texto,
      footer: 'Escolha uma opção para continuar:',
      buttons: [
        {
          type: 'quick_reply',
          id: JSON.stringify(button_payload_sim),
          text: '✅ Sim'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify(button_payload_nao),
          text: '❌ Não'
        }
      ]
    };
    console.log('[REENVIAR BOTÃO] 📡 Reenviando botão...');
    const wameResponse = await fetch(api_url, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(request_body)
    });
    if (!wameResponse.ok) {
      const responseBody = await wameResponse.text();
      throw new Error(`[WAME] Erro ${wameResponse.status}: ${responseBody}`);
    }
    console.log('[REENVIAR BOTÃO] ✅ Botão reenviado com sucesso');
    // ============================================
    // 6. RETORNAR SUCESSO
    // ============================================
    return new Response(JSON.stringify({
      success: true,
      message: 'Botão reenviado com sucesso',
      resubmitted: true,
      conversation_id: aguardando.conversation_id
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error('[REENVIAR BOTÃO] ❌ ERRO:', error.message);
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
