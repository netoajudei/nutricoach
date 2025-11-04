/**
 * @name webhook-wame
 * @version 2.0.0 (Bloqueio Educado)
 * @author NutriCoach AI Development Team
 * @date 2025-11-04 01:35:00 -03:00
 *
 * @description
 * Endpoint de Webhook para receber mensagens do provedor `api-wa.me`.
 * VERSÃO COM SISTEMA DE BLOQUEIO EDUCADO implementado.
 *
 * @changelog
 * - v2.0.0 (2025-11-04): Sistema de bloqueio educado
 *   - Implementado checkpoint que verifica aguardando_confirmacao
 *   - Mensagens não-botão durante bloqueio acionam reenvio
 *   - Cases de cancelamento unificados e acionam cancelar-registro
 *   - Removida duplicação de cases
 *   - SELECT do aluno agora inclui aguardando_confirmacao
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
    console.log('[WEBHOOK-WAME] ===== PAYLOAD RECEBIDO =====');
    const { instance: key, data } = body;
    // ========================================
    // VALIDAÇÕES DEFENSIVAS
    // ========================================
    if (!key) {
      throw new Error("Chave de instância (instance) ausente no payload");
    }
    if (!data) {
      throw new Error("Objeto 'data' ausente no payload");
    }
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
    if (!data.remoteJid) {
      if (data.from) {
        data.remoteJid = data.from;
      } else if (data.sender) {
        data.remoteJid = data.sender;
      } else {
        throw new Error("Não foi possível encontrar o número do WhatsApp");
      }
    }
    const whatsappNumber = data.remoteJid.replace(/\D/g, '');
    console.log('[WEBHOOK-WAME] 📱 WhatsApp:', whatsappNumber);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR ALUNO (COM aguardando_confirmacao)
    // ========================================
    const { data: aluno, error: alunoError } = await supabase.from('alunos').select('id, aguardando_confirmacao').eq('whatsapp', whatsappNumber).single();
    if (alunoError || !aluno) {
      console.warn('[WEBHOOK-WAME] ⚠️ Usuário desconhecido');
      return new Response('ok: unknown user', {
        headers: corsHeaders
      });
    }
    console.log('[WEBHOOK-WAME] ✅ Aluno ID:', aluno.id);
    // ========================================
    // CHECKPOINT: VERIFICAR BLOQUEIO
    // ========================================
    if (aluno.aguardando_confirmacao?.aguardando === true) {
      console.log('[WEBHOOK-WAME] 🔒 BLOQUEIO ATIVO detectado');
      // Se É botão → deixa continuar
      if (data.messageType === 'messageContextInfo') {
        console.log('[WEBHOOK-WAME] ✅ É botão, prosseguindo...');
      } else {
        // Se NÃO é botão → reenvia e PARA
        console.log('[WEBHOOK-WAME] ⏸️ Reenviando confirmação...');
        await supabase.functions.invoke('reenviar-botao-confirmacao', {
          body: {
            aluno_id: aluno.id,
            whatsapp: whatsappNumber
          }
        });
        return new Response(JSON.stringify({
          success: true,
          blocked: true,
          message: 'Aguardando confirmação pendente'
        }), {
          headers: {
            ...corsHeaders,
            'Content-Type': 'application/json'
          }
        });
      }
    }
    // ========================================
    // ENVIAR STATUS "ESCREVENDO..."
    // ========================================
    const presenceUrl = `https://us.api-wa.me/${key}/message/presence`;
    fetch(presenceUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        to: data.remoteJid,
        status: "composing"
      })
    }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao enviar status:", err.message));
    // ========================================
    // PROCESSAR TIPO DE MENSAGEM
    // ========================================
    console.log('[WEBHOOK-WAME] 📨 Tipo:', data.messageType);
    switch(data.messageType){
      // ========================================
      // MENSAGEM DE TEXTO
      // ========================================
      case 'conversation':
      case 'extendedTextMessage':
        {
          let mensagemUsuario = data.msgContent?.conversation || data.msgContent?.text || data.msgContent?.extendedTextMessage?.text || data.text || data.conversation || '';
          if (!mensagemUsuario) {
            console.warn('[WEBHOOK-WAME] ⚠️ Mensagem vazia');
            return new Response('ok: empty message', {
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
          console.log('[WEBHOOK-WAME] ✅ Mensagem inserida');
          break;
        }
      // ========================================
      // MENSAGEM DE ÁUDIO
      // ========================================
      case 'audioMessage':
        {
          const audioBase64 = data.fileBase64?.split(',')[1] || data.fileBase64;
          if (!audioBase64) {
            console.warn('[WEBHOOK-WAME] ⚠️ Áudio vazio');
            return new Response('ok: empty audio', {
              headers: corsHeaders
            });
          }
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
          if (insertError) {
            throw new Error(`Erro ao criar placeholder: ${insertError.message}`);
          }
          console.log('[WEBHOOK-WAME] ✅ Áudio recebido, acionando transcrição...');
          supabase.functions.invoke('transcrever-audio', {
            body: {
              mensagem_id: novaMensagem.id
            }
          }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro ao transcrever:", err));
          break;
        }
      // ========================================
      // RESPOSTA DE BOTÃO
      // ========================================
      case 'messageContextInfo':
        {
          console.log('[WEBHOOK-WAME] 🔘 Botão detectado');
          const buttonsResponse = data.msgContent?.buttonsResponseMessage;
          if (!buttonsResponse) {
            console.warn('[WEBHOOK-WAME] ⚠️ buttonsResponseMessage não encontrado');
            return new Response('ok: empty button', {
              headers: corsHeaders
            });
          }
          // ========================================
          // PROTEÇÃO CONTRA DUPLICATAS
          // ========================================
          const messageId = data.key?.id || data.messageId;
          if (!messageId) {
            console.error('[WEBHOOK-WAME] ❌ messageId ausente');
            return new Response('ok: no message id', {
              headers: corsHeaders
            });
          }
          const { data: existingMessage } = await supabase.from('processed_webhook_messages').select('id, status').eq('message_id', messageId).single();
          if (existingMessage) {
            if (existingMessage.status === 'processing') {
              console.log('[WEBHOOK-WAME] ⏳ Já processando');
              return new Response(JSON.stringify({
                success: true,
                message: "Já processando"
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                }
              });
            }
            if (existingMessage.status === 'completed') {
              console.log('[WEBHOOK-WAME] ✅ Já processado');
              return new Response(JSON.stringify({
                success: true,
                message: "Já processado"
              }), {
                headers: {
                  ...corsHeaders,
                  'Content-Type': 'application/json'
                }
              });
            }
            if (existingMessage.status === 'failed') {
              console.log('[WEBHOOK-WAME] 🔄 Reprocessando falha');
            }
          }
          // Registrar como processing
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
          if (insertError?.code === '23505') {
            console.log('[WEBHOOK-WAME] ⏭️ Já está processando');
            return new Response('ok: already processing', {
              headers: corsHeaders
            });
          }
          // ========================================
          // PARSE DO BOTÃO
          // ========================================
          let buttonData;
          try {
            buttonData = JSON.parse(buttonsResponse.selectedButtonId);
            console.log('[WEBHOOK-WAME] ✅ Button data:', buttonData);
          } catch (err) {
            console.error('[WEBHOOK-WAME] ❌ Parse error:', err.message);
            await supabase.from('processed_webhook_messages').update({
              status: 'failed'
            }).eq('message_id', messageId);
            throw new Error('Formato inválido do buttonId');
          }
          const { action } = buttonData;
          console.log('[WEBHOOK-WAME] 🎯 Action:', action);
          // ========================================
          // SWITCH DE AÇÕES
          // ========================================
          try {
            switch(action){
              // ==========================================
              // CONFIRMAR ATUALIZAÇÃO DE CARGA
              // ==========================================
              case 'confirmar_update_carga':
                {
                  console.log('[WEBHOOK-WAME] 💪 Confirmando carga');
                  const { exercicio_id, nova_carga, aluno_id } = buttonData;
                  if (!exercicio_id || !nova_carga || !aluno_id) {
                    throw new Error('Dados incompletos');
                  }
                  // 1️⃣ EXECUTAR RPC (já existente)
                  const { data: rpcResult, error: rpcError } = await supabase.rpc('atualizar_carga_exercicio', {
                    p_exercicio_id: exercicio_id,
                    p_aluno_id: aluno_id,
                    p_nova_carga: nova_carga,
                    p_whatsapp: whatsappNumber
                  });
                  if (rpcError) throw rpcError;
                  console.log('[WEBHOOK-WAME] ✅ Carga atualizada');
                  // 2️⃣ BUSCAR DADOS PARA FINALIZAÇÃO
                  const { data: alunoData } = await supabase.from('alunos').select('aguardando_confirmacao').eq('id', aluno_id).single();
                  const { conversation_id, tool_call_id } = alunoData?.aguardando_confirmacao || {};
                  // 3️⃣ FINALIZAR FUNCTION CALLING + LIMPAR BLOQUEIO
                  if (conversation_id && tool_call_id) {
                    console.log('[WEBHOOK-WAME] 🔄 Finalizando function calling...');
                    // Chamar função que finaliza + envia resposta + limpa bloqueio
                    await supabase.functions.invoke('finalizar-e-limpar', {
                      body: {
                        aluno_id: aluno_id,
                        whatsapp: whatsappNumber,
                        conversation_id: conversation_id,
                        tool_call_id: tool_call_id,
                        mensagem_sucesso: `✅ Carga atualizada com sucesso! ${rpcResult?.exercicio?.nome}: ${rpcResult?.exercicio?.carga_anterior}kg → ${rpcResult?.exercicio?.carga_nova}kg 💪`
                      }
                    });
                    console.log('[WEBHOOK-WAME] ✅ Function calling finalizado e bloqueio limpo');
                  } else {
                    // Se não tem bloqueio, envia mensagem simples
                    const exercicioData = rpcResult?.exercicio;
                    const mensagem = `✅ Carga atualizada! ${exercicioData?.nome}: ${exercicioData?.carga_anterior}kg → ${exercicioData?.carga_nova}kg 💪`;
                    fetch(`https://us.api-wa.me/${key}/message/text`, {
                      method: 'POST',
                      headers: {
                        'Content-Type': 'application/json'
                      },
                      body: JSON.stringify({
                        to: whatsappNumber,
                        text: mensagem
                      })
                    }).catch(console.error);
                  }
                  break;
                }
              // ==========================================
              // CONFIRMAR REGISTRO DE REFEIÇÃO
              // ==========================================
              case 'confirmar_registro_refeicao':
                {
                  console.log('[WEBHOOK-WAME] 🍽️ Confirmando refeição');
                  const { registro_id, aluno_id } = buttonData;
                  if (!registro_id || !aluno_id) {
                    throw new Error('Dados incompletos');
                  }
                  // 1️⃣ EXECUTAR RPC (já existente)
                  const { data: rpcResult, error: rpcError } = await supabase.rpc('processar_confirmacao_refeicao', {
                    p_registro_id: registro_id,
                    p_confirmar: true
                  });
                  if (rpcError) throw rpcError;
                  console.log('[WEBHOOK-WAME] ✅ Refeição confirmada');
                  // 2️⃣ BUSCAR DADOS PARA FINALIZAÇÃO
                  const { data: alunoData } = await supabase.from('alunos').select('aguardando_confirmacao').eq('id', aluno_id).single();
                  const { conversation_id, tool_call_id } = alunoData?.aguardando_confirmacao || {};
                  // 3️⃣ FINALIZAR FUNCTION CALLING + LIMPAR BLOQUEIO
                  if (conversation_id && tool_call_id) {
                    console.log('[WEBHOOK-WAME] 🔄 Finalizando function calling...');
                    await supabase.functions.invoke('finalizar-e-limpar', {
                      body: {
                        aluno_id: aluno_id,
                        whatsapp: whatsappNumber,
                        conversation_id: conversation_id,
                        tool_call_id: tool_call_id,
                        mensagem_sucesso: '✅ Refeição registrada com sucesso! Seus macros foram atualizados. Continue assim! 💪'
                      }
                    });
                    console.log('[WEBHOOK-WAME] ✅ Function calling finalizado e bloqueio limpo');
                  } else {
                    // Se não tem bloqueio, envia mensagem simples
                    fetch(`https://us.api-wa.me/${key}/message/text`, {
                      method: 'POST',
                      headers: {
                        'Content-Type': 'application/json'
                      },
                      body: JSON.stringify({
                        to: whatsappNumber,
                        text: '✅ Refeição registrada!'
                      })
                    }).catch(console.error);
                  }
                  break;
                }
              // ==========================================
              // CANCELAR QUALQUER AÇÃO (GENÉRICO)
              // ==========================================
              case 'cancelar_update_carga':
              case 'cancelar_registro_refeicao':
                {
                  console.log('[WEBHOOK-WAME] ❌ Cancelando ação');
                  const { aluno_id } = buttonData;
                  if (!aluno_id) {
                    throw new Error('aluno_id ausente');
                  }
                  // Buscar dados necessários
                  const { data: alunoData, error: alunoDataError } = await supabase.from('alunos').select('aguardando_confirmacao').eq('id', aluno_id).single();
                  if (alunoDataError || !alunoData) {
                    throw new Error('Não foi possível buscar dados do aluno');
                  }
                  const { conversation_id, tool_call_id } = alunoData.aguardando_confirmacao || {};
                  if (!conversation_id || !tool_call_id) {
                    throw new Error('conversation_id ou tool_call_id não encontrados');
                  }
                  console.log('[WEBHOOK-WAME] 🚀 Acionando cancelar-registro...');
                  await supabase.functions.invoke('cancelar-registro', {
                    body: {
                      aluno_id: aluno_id,
                      whatsapp: whatsappNumber,
                      conversation_id: conversation_id,
                      tool_call_id: tool_call_id
                    }
                  });
                  console.log('[WEBHOOK-WAME] ✅ Cancelamento processado');
                  break;
                }
              // ==========================================
              // ACTION DESCONHECIDA
              // ==========================================
              default:
                {
                  console.warn('[WEBHOOK-WAME] ⚠️ Action desconhecida:', action);
                  console.warn('[WEBHOOK-WAME] Data:', JSON.stringify(buttonData, null, 2));
                }
            }
            // Marcar como concluído
            await supabase.from('processed_webhook_messages').update({
              status: 'completed'
            }).eq('message_id', messageId);
            console.log('[WEBHOOK-WAME] ✅ Status: completed');
          } catch (actionError) {
            console.error('[WEBHOOK-WAME] ❌ Erro na action:', actionError.message);
            await supabase.from('processed_webhook_messages').update({
              status: 'failed'
            }).eq('message_id', messageId);
            throw actionError;
          }
          break;
        }
      // ========================================
      // TIPO NÃO SUPORTADO
      // ========================================
      default:
        {
          console.warn('[WEBHOOK-WAME] ⚠️ Tipo não suportado:', data.messageType);
          return new Response('ok: unsupported type', {
            headers: corsHeaders
          });
        }
    }
    console.log('[WEBHOOK-WAME] ✅ Processado');
    return new Response(JSON.stringify({
      success: true,
      message: "Mensagem recebida"
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      }
    });
  } catch (error) {
    console.error('🔥 ERRO no Webhook:', error.message);
    console.error('🔥 Stack:', error.stack);
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
