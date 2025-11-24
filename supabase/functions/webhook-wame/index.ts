/**
 * @name webhook-wame
 * @version 4.1.0
 * @author NutriCoach AI Development Team
 * 
 * @description
 * Webhook para receber mensagens do WAME.
 * Sistema de botões dinâmico com tabela botoes_ativos.
 * Suporte a vinculação UUID/@lid para onboarding.
 * 
 * @changelog
 * - v4.1.0: Adicionado suporte a vinculação UUID/@lid
 *   - Detecção correta de @lid via data.isLid
 *   - Ramificação para UUID quando aluno não encontrado
 *   - Mensagem de boas-vindas automática
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
    console.log('[WEBHOOK-WAME v4.1] 📥 Webhook recebido');
    const body = await req.json();
    // 🔥 LOG COMPLETO DO PAYLOAD RECEBIDO
    console.log('═══════════════════════════════════════');
    console.log('📦 PAYLOAD COMPLETO RECEBIDO:');
    console.log(JSON.stringify(body, null, 2));
    console.log('═══════════════════════════════════════');
    const data = body.data || body;
    if (!data) {
      console.warn('[WEBHOOK-WAME] ⚠️ Payload vazio');
      return new Response('ok: empty', {
        headers: corsHeaders
      });
    }
    console.log('[WEBHOOK-WAME] 📋 Message Type:', data.messageType);
    // ========================================
    // EXTRAIR WHATSAPP
    // ========================================
    const whatsappNumber = data.key?.remoteJid?.replace('@s.whatsapp.net', '') || data.from?.replace('@s.whatsapp.net', '') || data.remoteJid?.replace('@s.whatsapp.net', '');
    if (!whatsappNumber) {
      console.warn('[WEBHOOK-WAME] ⚠️ WhatsApp não identificado');
      return new Response('ok: no whatsapp', {
        headers: corsHeaders
      });
    }
    console.log('[WEBHOOK-WAME] 📱 WhatsApp:', whatsappNumber);
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    // ========================================
    // BUSCAR OU CRIAR ALUNO
    // ========================================
    console.log('[WEBHOOK-WAME] 🔍 Buscando aluno...');
    let { data: aluno, error: alunoError } = await supabase.from('alunos').select('id, whatsapp').eq('whatsapp', whatsappNumber).single();
    // ========================================
    // RAMIFICAÇÃO: SE ALUNO NÃO ENCONTRADO
    // ========================================
    // ========================================
    // ========================================
    // SUBSTITUIR O BLOCO COMPLETO "if (alunoError || !aluno)"
    // Das linhas ~60 até ~150
    // ========================================
    if (alunoError || !aluno) {
      console.log('[WEBHOOK-WAME] 👤 Aluno não encontrado');
      // ========================================
      // DETECÇÃO DE @LID (FORMA CORRETA)
      // ========================================
      const isLid = data.onlyLid === true || data.isLid === true || whatsappNumber.includes('@lid');
      if (isLid) {
        console.log('[WEBHOOK-WAME] 🔐 Mensagem @lid detectada');
        // Extrair conteúdo da mensagem
        let mensagemTexto = data.msgContent?.conversation || data.msgContent?.text || data.msgContent?.extendedTextMessage?.text || data.text || data.conversation || '';
        mensagemTexto = mensagemTexto.trim();
        console.log('[WEBHOOK-WAME] 📝 Conteúdo:', mensagemTexto);
        // ========================================
        // VERIFICAR SE É UUID (36 caracteres)
        // ========================================
        const uuidRegex = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
        const isUUID = mensagemTexto.length === 36 && uuidRegex.test(mensagemTexto);
        if (isUUID) {
          console.log('[WEBHOOK-WAME] 🆔 UUID detectado:', mensagemTexto);
          // Buscar aluno pelo UUID
          const { data: alunoByUuid, error: uuidError } = await supabase.from('alunos').select('id, nome_completo').eq('id', mensagemTexto).single();
          if (alunoByUuid) {
            console.log('[WEBHOOK-WAME] ✅ Aluno encontrado:', alunoByUuid.nome_completo);
            // remoteJid já vem completo com @lid
            const whatsappParaSalvar = data.remoteJid;
            // Atualizar WhatsApp do aluno
            const { error: updateError } = await supabase.from('alunos').update({
              whatsapp: whatsappParaSalvar,
              last_interaction_at: new Date().toISOString()
            }).eq('id', mensagemTexto);
            if (updateError) {
              console.error('[WEBHOOK-WAME] ❌ Erro ao atualizar:', updateError);
              throw updateError;
            }
            console.log('[WEBHOOK-WAME] ✅ WhatsApp vinculado:', whatsappParaSalvar);
            // Enviar mensagem de boas-vindas
            const { data: configData } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
            if (configData) {
              const mensagemBoasVindas = `✅ *Cadastro concluído com sucesso!*

Olá ${alunoByUuid.nome_completo}, seja bem-vindo(a) ao ZapNutri! 💪

Agora você já pode conversar comigo. Como posso te ajudar hoje?`;
              await fetch(`https://us.api-wa.me/${configData.valor}/message/text`, {
                method: 'POST',
                headers: {
                  'Content-Type': 'application/json'
                },
                body: JSON.stringify({
                  to: data.remoteJid,
                  text: mensagemBoasVindas
                })
              }).catch((err)=>console.error('[WEBHOOK-WAME] Erro ao enviar boas-vindas:', err));
              console.log('[WEBHOOK-WAME] 📤 Mensagem de boas-vindas enviada');
            }
            // Parar processamento aqui - UUID foi processado
            return new Response('ok: uuid vinculado', {
              headers: corsHeaders
            });
          } else {
            console.log('[WEBHOOK-WAME] ⚠️ UUID não encontrado no banco');
          }
        }
        // ========================================
        // @LID SEM UUID VÁLIDO - IGNORAR
        // ========================================
        console.log('[WEBHOOK-WAME] ⚠️ @lid sem UUID válido - ignorando');
        return new Response('ok: lid sem uuid', {
          headers: corsHeaders
        });
      }
      // ========================================
      // ALUNO NÃO CADASTRADO - IGNORAR
      // ========================================
      console.log('[WEBHOOK-WAME] ⚠️ Aluno não cadastrado - ignorando mensagem');
      return new Response('ok: aluno nao cadastrado', {
        headers: corsHeaders
      });
    } else {
      console.log('[WEBHOOK-WAME] ✅ Aluno encontrado:', aluno.id);
    }
    // ========================================
    // SWITCH POR TIPO DE MENSAGEM
    // ========================================
    console.log('[WEBHOOK-WAME] 📨 Tipo:', data.messageType);
    switch(data.messageType){
      // ========================================
      // CASE 1: MENSAGEM DE TEXTO
      // ========================================
      case 'conversation':
      case 'extendedTextMessage':
        {
          console.log('[WEBHOOK-WAME] 💬 Mensagem de texto');
          // ========================================
          // VERIFICAR BOTÃO ATIVO (BLOQUEIO)
          // ========================================
          console.log('[WEBHOOK-WAME] 🔍 Verificando botão ativo...');
          const { data: botaoAtivo, error: botaoError } = await supabase.from('botoes_ativos').select('*').eq('aluno_id', aluno.id).maybeSingle();
          if (botaoAtivo) {
            console.log('[WEBHOOK-WAME] 🔴 BLOQUEADO - Botão ativo encontrado');
            console.log('[WEBHOOK-WAME] 📋 Tipo:', botaoAtivo.tipo_acao);
            console.log('[WEBHOOK-WAME] 🆔 Botão ID:', botaoAtivo.id);
            // Reenviar botão pendente
            console.log('[WEBHOOK-WAME] 🔄 Reenviando botão pendente...');
            await reenviarBotao(supabase, botaoAtivo, whatsappNumber);
            console.log('[WEBHOOK-WAME] ✅ Botão reenviado');
            return new Response('ok: botão reenviado', {
              headers: corsHeaders
            });
          }
          console.log('[WEBHOOK-WAME] ✅ Sem bloqueio - Processando normalmente');
          let mensagemUsuario = data.msgContent?.conversation || data.msgContent?.text || data.msgContent?.extendedTextMessage?.text || data.text || data.conversation || '';
          if (!mensagemUsuario) {
            console.warn('[WEBHOOK-WAME] ⚠️ Mensagem vazia');
            return new Response('ok: empty message', {
              headers: corsHeaders
            });
          }
          // Adicionar timestamp
          const timestampMs = (data.messageTimestamp?.low || data.messageTimestamp) * 1000;
          const dataHora = new Date(timestampMs);
          const dataHoraSP = dataHora.toLocaleString('pt-BR', {
            timeZone: 'America/Sao_Paulo',
            weekday: 'long',
            day: '2-digit',
            month: '2-digit',
            hour: '2-digit',
            minute: '2-digit',
            hour12: false
          });
          const partes = dataHoraSP.split(', ');
          const diaSemana = partes[0];
          const diaEMes = partes[1].substring(0, 5);
          const hora = partes[2];
          const dataFormatada = `${diaSemana} ${diaEMes} ${hora}`;
          mensagemUsuario = `<data>${dataFormatada}</data> ${mensagemUsuario}`;
          console.log('[WEBHOOK-WAME] 📝 Mensagem:', mensagemUsuario.substring(0, 100));
          // Inserir mensagem
          const { data: mensagemData, error: msgError } = await supabase.from('mensagens_temporarias').insert({
            aluno_id: aluno.id,
            whatsapp: whatsappNumber,
            chat_id: `${whatsappNumber}@c.us`,
            agregado: true,
            mensagem: mensagemUsuario,
            tipo: 'text',
            timestamp_mensagem: new Date(timestampMs).toISOString()
          }).select('id').single();
          if (msgError) {
            throw new Error(`Erro ao inserir mensagem: ${msgError.message}`);
          }
          console.log('[WEBHOOK-WAME] ✅ Mensagem inserida:', mensagemData.id);
          // Acionar orquestrador
          console.log('[WEBHOOK-WAME] 🚀 Acionando orquestrador...');
          supabase.functions.invoke('orquestrador-ia', {
            body: {
              mensagem_id: mensagemData.id
            }
          }).catch((err)=>{
            console.error('[WEBHOOK-WAME] ❌ Erro ao acionar orquestrador:', err);
          });
          break;
        }
      // ========================================
      // CASE 2: BOTÃO (messageContextInfo)
      // ========================================
      case 'messageContextInfo':
        {
          console.log('[WEBHOOK-WAME] 🔘 Botão detectado');
          const buttonsResponse = data.msgContent?.buttonsResponseMessage;
          if (!buttonsResponse) {
            console.warn('[WEBHOOK-WAME] ⚠️ buttonsResponseMessage não encontrado');
            return new Response('ok: no button data', {
              headers: corsHeaders
            });
          }
          console.log('[WEBHOOK-WAME] 📋 selectedButtonId:', buttonsResponse.selectedButtonId);
          // Parse do botão
          let buttonData;
          try {
            buttonData = JSON.parse(buttonsResponse.selectedButtonId);
            console.log('[WEBHOOK-WAME] ✅ Button data parsed:', buttonData);
          } catch (parseError) {
            console.error('[WEBHOOK-WAME] ❌ Erro ao parsear botão:', parseError);
            return new Response('ok: erro parse', {
              headers: corsHeaders
            });
          }
          const { action } = buttonData;
          console.log('[WEBHOOK-WAME] 🎯 Action:', action);
          // Roteamento dinâmico
          if (action === 'resposta_botao') {
            console.log('[WEBHOOK-WAME] 🎯 Processando resposta de botão');
            const { botao_id, confirmado } = buttonData;
            if (!botao_id) {
              throw new Error('botao_id ausente');
            }
            console.log('[WEBHOOK-WAME] 🔍 Buscando botão:', botao_id);
            console.log('[WEBHOOK-WAME] 📋 Confirmado:', confirmado);
            // Buscar botão no banco
            const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('edge_function, tipo_acao').eq('id', botao_id).single();
            if (botaoErr || !botao) {
              console.error('[WEBHOOK-WAME] ❌ Botão não encontrado:', botaoErr?.message);
              throw new Error('Botão não encontrado no banco');
            }
            console.log('[WEBHOOK-WAME] ✅ Botão encontrado');
            console.log('[WEBHOOK-WAME] 📦 Tipo:', botao.tipo_acao);
            console.log('[WEBHOOK-WAME] 🎯 Edge Function:', botao.edge_function);
            // Invocar edge function
            console.log('[WEBHOOK-WAME] 🚀 Invocando', botao.edge_function);
            const { error: edgeError } = await supabase.functions.invoke(botao.edge_function, {
              body: {
                botao_id: botao_id,
                confirmado: confirmado
              }
            });
            if (edgeError) {
              console.error('[WEBHOOK-WAME] ❌ Erro na edge function:', edgeError);
              throw edgeError;
            }
            console.log('[WEBHOOK-WAME] ✅ Botão processado com sucesso!');
          } else {
            console.warn('[WEBHOOK-WAME] ⚠️ Action desconhecida:', action);
          }
          break;
        }
      // ========================================
      // CASE 3: ÁUDIO
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
          const timestampMs = (data.messageTimestamp?.low || data.messageTimestamp) * 1000;
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
          console.log('[WEBHOOK-WAME] ✅ Áudio recebido');
          supabase.functions.invoke('transcrever-audio', {
            body: {
              mensagem_id: novaMensagem.id
            }
          }).catch((err)=>console.error("[WEBHOOK-WAME] ⚠️ Erro transcrição:", err));
          break;
        }
      // ========================================
      // DEFAULT
      // ========================================
      default:
        console.warn('[WEBHOOK-WAME] ⚠️ Tipo não suportado:', data.messageType);
        return new Response('ok: unsupported', {
          headers: corsHeaders
        });
    }
    return new Response('ok', {
      headers: corsHeaders
    });
  } catch (error) {
    console.error('[WEBHOOK-WAME] ❌ ERRO:', error.message);
    console.error('[WEBHOOK-WAME] Stack:', error.stack);
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
// ========================================
// FUNÇÃO AUXILIAR: REENVIAR BOTÃO
// ========================================
async function reenviarBotao(supabase, botao, whatsappNumber) {
  try {
    console.log('[REENVIAR BOTÃO] 🔄 Iniciando reenvio...');
    const { argumentos, tipo_acao, id } = botao;
    // Buscar API key
    const { data: configData } = await supabase.from('config_sistema').select('valor').eq('chave', 'wame_api_key').single();
    if (!configData) {
      throw new Error('WAME_API_KEY não encontrada');
    }
    const api_key = configData.valor;
    // Montar mensagem e botões baseado no tipo
    let mensagem, header, buttons;
    if (tipo_acao === 'update_carga') {
      const { nome_exercicio, carga_atual, nova_carga } = argumentos;
      mensagem = `💪 Você tem uma confirmação pendente!

Deseja atualizar a carga de *${nome_exercicio}* de ${carga_atual}kg para ${nova_carga}kg?`;
      header = {
        title: '💪 Confirmação Pendente'
      };
      buttons = [
        {
          type: 'quick_reply',
          id: JSON.stringify({
            action: 'resposta_botao',
            botao_id: id,
            confirmado: true
          }),
          text: '✅ Sim, atualizar!'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify({
            action: 'resposta_botao',
            botao_id: id,
            confirmado: false
          }),
          text: '❌ Não, manter'
        }
      ];
    } else if (tipo_acao === 'registro_refeicao') {
      const { refeicao, tipo, calorias } = argumentos;
      mensagem = `🍽️ Você tem uma confirmação pendente!

Confirmar registro de ${tipo}?
${refeicao.substring(0, 100)}...
${calorias} kcal`;
      header = {
        title: '🍽️ Confirmação Pendente'
      };
      buttons = [
        {
          type: 'quick_reply',
          id: JSON.stringify({
            action: 'resposta_botao',
            botao_id: id,
            confirmado: true
          }),
          text: '✅ Sim, registrar!'
        },
        {
          type: 'quick_reply',
          id: JSON.stringify({
            action: 'resposta_botao',
            botao_id: id,
            confirmado: false
          }),
          text: '❌ Não, alterar'
        }
      ];
    }
    // Enviar botão
    const response = await fetch(`https://us.api-wa.me/${api_key}/message/button_reply`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        to: whatsappNumber,
        header: header,
        text: mensagem,
        footer: 'Por favor, responda para continuar:',
        buttons: buttons
      })
    });
    if (!response.ok) {
      throw new Error(`Erro ao reenviar: ${response.status}`);
    }
    console.log('[REENVIAR BOTÃO] ✅ Botão reenviado com sucesso');
  } catch (error) {
    console.error('[REENVIAR BOTÃO] ❌ Erro:', error.message);
    throw error;
  }
}
