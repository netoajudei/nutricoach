/**
 * @name webhook-wame
 * @version 1.6.0 (Proteção contra Duplicatas)
 * @author NutriCoach AI Development
 * @date 2025-10-18
 *
 * @description
 * Endpoint de Webhook para receber mensagens do provedor `api-wa.me`.
 * VERSÃO COM PROTEÇÃO CONTRA DUPLICATAS usando messageId.
 *
 * @changelog
 * - v1.6.0:
 * - Implementada verificação de idempotência por messageId
 * - Adicionada tabela processed_webhook_messages para controle
 * - Prevenção de processamento múltiplo de botões
 */ /**
 * @name webhook-wame
 * @version 1.7.0 (Multi-Action Switch)
 * @author NutriCoach AI Development
 * @date 2025-10-18
 *
 * @description
 * Endpoint de Webhook para receber mensagens do provedor `api-wa.me`.
 * 
 * @changelog
 * - v1.7.0: Implementado switch para múltiplas ações de botões
 *   - confirmar_update_carga
 *   - cancelar_update_carga
 *   - confirmar_registro_refeicao (NOVO)
 *   - cancelar_registro_refeicao (NOVO)
 */ /**
 * @name webhook-wame
 * @version 1.8.0 (Status Processing)
 * @author NutriCoach AI Development
 * @date 2025-10-18
 *
 * @description
 * Endpoint de Webhook para receber mensagens do provedor `api-wa.me`.
 * 
 * @changelog
 * - v1.8.0: Implementado sistema de status (processing/completed/failed)
 *   para evitar duplicatas mas permitir reprocessamento em caso de falha
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
    const body = await req.json();
    console.log('[WEBHOOK-WAME] ===== PAYLOAD COMPLETO RECEBIDO =====');
    console.log('[WEBHOOK-WAME] Payload bruto:', JSON.stringify(body, null, 2));
    const { instance: key, data } = body;
    // ========================================
    // VALIDAÇÕES DEFENSIVAS
    // ========================================
    if (!key) {
      console.error('[WEBHOOK-WAME] ❌ Falta a chave "instance" no payload');
      throw new Error("Chave de instância (instance) ausente no payload");
    }
    if (!data) {
      console.error('[WEBHOOK-WAME] ❌ Falta o objeto "data" no payload');
      throw new Error("Objeto 'data' ausente no payload");
    }
    console.log('[WEBHOOK-WAME] ✅ Validação inicial passou');
    // Verificar se é mensagem de grupo
    if (data.isGroup) {
      console.log('[WEBHOOK-WAME] ℹ️ Mensagem de grupo ignorada');
      return new Response('ok: group message ignored', {
        headers: corsHeaders
      });
    }
    // ========================================
    // EXTRAIR NÚMERO DO WHATSAPP
    // ========================================
    console.log('[WEBHOOK-WAME] 📱 Verificando remoteJid...');
    if (!data.remoteJid) {
      console.error('[WEBHOOK-WAME] ❌ remoteJid não encontrado');
      if (data.from) {
        console.log('[WEBHOOK-WAME] ℹ️ Usando campo "from" como alternativa');
        data.remoteJid = data.from;
      } else if (data.sender) {
        console.log('[WEBHOOK-WAME] ℹ️ Usando campo "sender" como alternativa');
        data.remoteJid = data.sender;
      } else {
        throw new Error("Não foi possível encontrar o número do WhatsApp");
      }
    }
    const whatsappNumber = data.remoteJid.replace(/\D/g, '');
    console.log('[WEBHOOK-WAME] ✅ Número extraído:', whatsappNumber);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // Buscar aluno
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('id').eq('whatsapp', whatsappNumber).single();
    if (alunoError || !aluno) {
      console.warn('[WEBHOOK-WAME] ⚠️ Usuário desconhecido. WhatsApp:', whatsappNumber);
      return new Response('ok: unknown user', {
        headers: corsHeaders
      });
    }
    console.log('[WEBHOOK-WAME] ✅ Aluno encontrado. ID:', aluno.id);
    // ========================================
    // ENVIAR STATUS "ESCREVENDO..."
    // ========================================
    const presenceUrl = `https://us.api-wa.me/${key}/message/presence`;
    const presencePayload = {
      to: data.remoteJid,
      status: "composing"
    };
    console.log(`[WEBHOOK-WAME] 📝 Enviando status 'composing' para ${data.remoteJid}`);
    fetch(presenceUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(presencePayload)
    }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Falha ao enviar status de presença:", err.message));
    // ========================================
    // PROCESSAR TIPO DE MENSAGEM
    // ========================================
    console.log('[WEBHOOK-WAME] 📨 Tipo de mensagem:', data.messageType);
    switch(data.messageType){
      case 'conversation':
      case 'extendedTextMessage':
        {
          console.log('[WEBHOOK-WAME] 📋 Estrutura de msgContent:', JSON.stringify(data.msgContent, null, 2));
          let mensagemUsuario = data.msgContent?.conversation || data.msgContent?.text || data.msgContent?.extendedTextMessage?.text || data.text || data.conversation || '';
          console.log('[WEBHOOK-WAME] Mensagem extraída:', mensagemUsuario);
          if (!mensagemUsuario) {
            console.warn('[WEBHOOK-WAME] ⚠️ Mensagem de texto vazia');
            return new Response('ok: empty text message', {
              headers: corsHeaders
            });
          }
          const timestampMs = (data.messageTimestamp.low || data.messageTimestamp) * 1000;
          await supabase.from('mensagens_temporarias').insert({
            aluno_id: aluno.id,
            whatsapp: whatsappNumber,
            chat_id: `${whatsappNumber}@c.us`,
            mensagem: mensagemUsuario,
            tipo: 'text',
            timestamp_mensagem: new Date(timestampMs).toISOString()
          });
          console.log('[WEBHOOK-WAME] ✅ Mensagem de texto inserida com sucesso');
          break;
        }
      case 'audioMessage':
        {
          const audioBase64 = data.fileBase64?.split(',')[1] || data.fileBase64;
          if (!audioBase64) {
            console.warn('[WEBHOOK-WAME] ⚠️ Áudio vazio');
            return new Response('ok: empty audio message', {
              headers: corsHeaders
            });
          }
          console.log(`[WEBHOOK-WAME] 🎙️ Áudio recebido. Criando placeholder para aluno ${aluno.id}`);
          const timestampMs = (data.messageTimestamp.low || data.messageTimestamp) * 1000;
          const { data: novaMensagem, error: insertError } = await supabase.from('mensagens_temporarias').insert({
            aluno_id: aluno.id,
            whatsapp: whatsappNumber,
            chat_id: `${whatsappNumber}@c.us`,
            mensagem: "[PROCESSANDO ÁUDIO...]",
            tipo: 'audio',
            tem_audio: true,
            audio_base64: audioBase64,
            timestamp_mensagem: new Date(timestampMs).toISOString(),
            agregado: true,
            tipo_mensagem: 'RECEBIDA'
          }).select('id').single();
          if (insertError) throw new Error(`Erro ao criar placeholder de áudio: ${insertError.message}`);
          console.log(`[WEBHOOK-WAME] ✅ Placeholder criado (ID: ${novaMensagem.id}). Disparando 'transcrever-audio'...`);
          supabase.functions.invoke('transcrever-audio', {
            body: {
              mensagem_id: novaMensagem.id
            }
          }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao invocar transcrever-audio:", err));
          break;
        }
      case 'messageContextInfo':
        {
          console.log('[WEBHOOK-WAME] 🔘 Resposta de botão detectada');
          const buttonsResponse = data.msgContent?.buttonsResponseMessage;
          if (!buttonsResponse) {
            console.warn('[WEBHOOK-WAME] ⚠️ buttonsResponseMessage não encontrado');
            return new Response('ok: empty button response', {
              headers: corsHeaders
            });
          }
          console.log('[WEBHOOK-WAME] selectedButtonId:', buttonsResponse.selectedButtonId);
          console.log('[WEBHOOK-WAME] selectedDisplayText:', buttonsResponse.selectedDisplayText);
          // ========================================
          // 🔒 PROTEÇÃO CONTRA DUPLICATAS COM STATUS
          // ========================================
          const messageId = data.key?.id || data.messageId;
          if (!messageId) {
            console.error('[WEBHOOK-WAME] ❌ messageId não encontrado no payload');
            return new Response('ok: no message id', {
              headers: corsHeaders
            });
          }
          console.log('[WEBHOOK-WAME] 🔍 Verificando status de processamento:', messageId);
          // Verificar se já está sendo processado ou já foi concluído
          const { data: existingMessage } = await supabase.from('processed_webhook_messages').select('id, status').eq('message_id', messageId).single();
          if (existingMessage) {
            if (existingMessage.status === 'processing') {
              console.log('[WEBHOOK-WAME] ⏳ Mensagem JÁ está sendo processada. Ignorando.');
              return new Response(JSON.stringify({
                success: true,
                message: "Mensagem já está sendo processada"
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                }
              });
            }
            if (existingMessage.status === 'completed') {
              console.log('[WEBHOOK-WAME] ✅ Mensagem JÁ foi processada com sucesso. Ignorando.');
              return new Response(JSON.stringify({
                success: true,
                message: "Mensagem já foi processada anteriormente"
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                }
              });
            }
            // Se status = 'failed', permite reprocessamento (não faz nada, segue o fluxo)
            if (existingMessage.status === 'failed') {
              console.log('[WEBHOOK-WAME] 🔄 Mensagem falhou anteriormente. Permitindo reprocessamento.');
            }
          }
          // Registrar como "processing"
          const { error: insertError } = await supabase.from('processed_webhook_messages').insert({
            message_id: messageId,
            event_type: 'button_response',
            aluno_id: aluno.id,
            status: 'processing',
            metadata: {
              selectedButtonId: buttonsResponse.selectedButtonId,
              selectedDisplayText: buttonsResponse.selectedDisplayText,
              remoteJid: data.remoteJid
            }
          });
          if (insertError) {
            if (insertError.code === '23505') {
              console.log('[WEBHOOK-WAME] ⏭️ Outra instância já está processando. Ignorando.');
              return new Response('ok: already processing', {
                headers: corsHeaders
              });
            }
            console.error('[WEBHOOK-WAME] ⚠️ Erro ao registrar mensagem:', insertError);
          }
          console.log('[WEBHOOK-WAME] ✅ Mensagem marcada como "processing"');
          // ========================================
          // PARSE DO JSON DO BOTÃO
          // ========================================
          let buttonData;
          try {
            buttonData = JSON.parse(buttonsResponse.selectedButtonId);
            console.log('[WEBHOOK-WAME] ✅ Button data parseado:', buttonData);
          } catch (err) {
            console.error('[WEBHOOK-WAME] ❌ Erro ao fazer parse do selectedButtonId:', err.message);
            // Marcar como failed
            await supabase.from('processed_webhook_messages').update({
              status: 'failed'
            }).eq('message_id', messageId);
            throw new Error('Formato inválido do buttonId');
          }
          const { action } = buttonData;
          console.log('[WEBHOOK-WAME] 🎯 Action detectada:', action);
          // ========================================
          // 🔀 SWITCH PARA MÚLTIPLAS AÇÕES
          // ========================================
          try {
            switch(action){
              // ==========================================
              // CASE 1: CONFIRMAR ATUALIZAÇÃO DE CARGA
              // ==========================================
              case 'confirmar_update_carga':
                {
                  console.log('[WEBHOOK-WAME] 💪 Processando confirmação de atualização de carga');
                  const { exercicio_id, nova_carga } = buttonData;
                  if (!exercicio_id || !nova_carga) {
                    console.error('[WEBHOOK-WAME] ❌ Dados incompletos para atualização de carga');
                    break;
                  }
                  console.log('[WEBHOOK-WAME] 🚀 Acionando RPC para atualizar carga do exercício...');
                  const { data: rpcResult, error: rpcError } = await supabase.rpc('atualizar_carga_exercicio', {
                    p_exercicio_id: exercicio_id,
                    p_aluno_id: aluno.id,
                    p_nova_carga: nova_carga,
                    p_whatsapp: whatsappNumber
                  });
                  if (rpcError) {
                    console.error('[WEBHOOK-WAME] ❌ Erro na RPC:', rpcError.message);
                    throw rpcError;
                  }
                  console.log('[WEBHOOK-WAME] ✅ RPC executada com sucesso:', JSON.stringify(rpcResult, null, 2));
                  // Enviar confirmação
                  const exercicioData = rpcResult?.exercicio;
                  const mensagemConfirmacao = `✅ Ótimo! Sua carga foi atualizada com sucesso!

*${exercicioData?.nome || 'Exercício'}*
${exercicioData?.carga_anterior}kg → *${exercicioData?.carga_nova}kg* 💪

Vamos lá! Essa carga extra vai fazer você ficar ainda mais forte nos próximos treinos! 🚀`;
                  console.log('[WEBHOOK-WAME] 📱 Enviando confirmação via WhatsApp...');
                  const textUrl = `https://us.api-wa.me/${key}/message/text`;
                  fetch(textUrl, {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                      to: whatsappNumber,
                      text: mensagemConfirmacao
                    })
                  }).then(()=>{
                    console.log('[WEBHOOK-WAME] ✅ Mensagem de confirmação enviada');
                  }).catch((err)=>{
                    console.error('[WEBHOOK-WAME] ⚠️ Erro ao enviar mensagem de confirmação:', err.message);
                  });
                  break;
                }
              // ==========================================
              // CASE 2: CANCELAR ATUALIZAÇÃO DE CARGA
              // ==========================================
              case 'cancelar_update_carga':
                {
                  console.log('[WEBHOOK-WAME] ℹ️ Usuário cancelou a atualização de carga');
                  const mensagemCancelamento = `Sem problema! 👍 Sua carga foi mantida como estava. Se quiser mudar depois, é só nos avisar!`;
                  const textUrl = `https://us.api-wa.me/${key}/message/text`;
                  fetch(textUrl, {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                      to: whatsappNumber,
                      text: mensagemCancelamento
                    })
                  }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao enviar cancelamento:", err.message));
                  break;
                }
              // ==========================================
              // CASE 3: CONFIRMAR REGISTRO DE REFEIÇÃO
              // ==========================================
              case 'confirmar_registro_refeicao':
                {
                  console.log('[WEBHOOK-WAME] 🍽️ Processando confirmação de registro de refeição');
                  const { registro_id } = buttonData;
                  if (!registro_id) {
                    console.error('[WEBHOOK-WAME] ❌ registro_id ausente');
                    throw new Error('registro_id é obrigatório');
                  }
                  console.log('[WEBHOOK-WAME] 🚀 Acionando RPC processar_confirmacao_refeicao...');
                  const { data: rpcResult, error: rpcError } = await supabase.rpc('processar_confirmacao_refeicao', {
                    p_registro_id: registro_id,
                    p_confirmar: true
                  });
                  if (rpcError) {
                    console.error('[WEBHOOK-WAME] ❌ Erro na RPC:', rpcError.message);
                    throw rpcError;
                  }
                  console.log('[WEBHOOK-WAME] ✅ Refeição confirmada com sucesso:', JSON.stringify(rpcResult, null, 2));
                  // Enviar confirmação
                  const mensagemConfirmacao = `✅ Refeição registrada com sucesso! 🎉

Seus macros foram atualizados e eu já estou acompanhando seu progresso de hoje.

Continue assim! 💪`;
                  const textUrl = `https://us.api-wa.me/${key}/message/text`;
                  fetch(textUrl, {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                      to: whatsappNumber,
                      text: mensagemConfirmacao
                    })
                  }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao enviar confirmação:", err.message));
                  break;
                }
              // ==========================================
              // CASE 4: CANCELAR REGISTRO DE REFEIÇÃO
              // ==========================================
              case 'cancelar_registro_refeicao':
                {
                  console.log('[WEBHOOK-WAME] 🗑️ Processando cancelamento de registro de refeição');
                  const { registro_id } = buttonData;
                  if (!registro_id) {
                    console.error('[WEBHOOK-WAME] ❌ registro_id ausente');
                    throw new Error('registro_id é obrigatório');
                  }
                  console.log('[WEBHOOK-WAME] 🚀 Acionando RPC processar_confirmacao_refeicao (cancelar)...');
                  const { data: rpcResult, error: rpcError } = await supabase.rpc('processar_confirmacao_refeicao', {
                    p_registro_id: registro_id,
                    p_confirmar: false
                  });
                  if (rpcError) {
                    console.error('[WEBHOOK-WAME] ❌ Erro na RPC:', rpcError.message);
                    throw rpcError;
                  }
                  console.log('[WEBHOOK-WAME] ✅ Refeição cancelada com sucesso:', JSON.stringify(rpcResult, null, 2));
                  // Enviar confirmação
                  const mensagemCancelamento = `Ok! 👍 Registro cancelado.

Quando quiser registrar suas refeições, é só me avisar o que você comeu!`;
                  const textUrl = `https://us.api-wa.me/${key}/message/text`;
                  fetch(textUrl, {
                    method: 'POST',
                    headers: {
                      'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({
                      to: whatsappNumber,
                      text: mensagemCancelamento
                    })
                  }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao enviar cancelamento:", err.message));
                  break;
                }
              // ==========================================
              // DEFAULT: ACTION NÃO RECONHECIDA
              // ==========================================
              default:
                {
                  console.warn('[WEBHOOK-WAME] ⚠️ Action desconhecida:', action);
                  console.warn('[WEBHOOK-WAME] Button data completo:', JSON.stringify(buttonData, null, 2));
                }
            }
            // 👉 SE CHEGOU ATÉ AQUI SEM ERRO = SUCESSO
            await supabase.from('processed_webhook_messages').update({
              status: 'completed'
            }).eq('message_id', messageId);
            console.log('[WEBHOOK-WAME] ✅ Status atualizado para "completed"');
          } catch (actionError) {
            // 👉 SE DEU ERRO NO PROCESSAMENTO = FAILED
            console.error('[WEBHOOK-WAME] ❌ Erro ao processar action:', actionError.message);
            await supabase.from('processed_webhook_messages').update({
              status: 'failed'
            }).eq('message_id', messageId);
            console.log('[WEBHOOK-WAME] ⚠️ Status atualizado para "failed"');
            throw actionError; // Re-throw para o catch externo
          }
        }
      default:
        {
          console.warn('[WEBHOOK-WAME] ⚠️ Tipo de mensagem não suportado:', data.messageType);
          return new Response('ok: unsupported message type', {
            headers: corsHeaders
          });
        }
    }
    console.log('[WEBHOOK-WAME] ✅ Webhook processado com sucesso');
    return new Response(JSON.stringify({
      success: true,
      message: "Mensagem recebida."
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('🔥 Erro no Webhook API-WA.ME:', error.message);
    console.error('🔥 Stack:', error.stack);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
