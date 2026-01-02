/**
 * @name webhook-wame
 * @version 4.2.0 (Patch Android/iOS sobre v4.1.0)
 * @author NutriCoach AI Development Team
 * * @description
 * Webhook para receber mensagens do WAME.
 * Sistema de botões dinâmico com tabela botoes_ativos.
 * Suporte a vinculação UUID/@lid para onboarding.
 * * @changelog
 * - v4.2.0: Adicionado suporte a templateButtonReplyMessage (Android) e interactiveMessage (iOS)
 * - v4.1.0: Adicionado suporte a vinculação UUID/@lid
 * - Detecção correta de @lid via data.isLid
 * - Ramificação para UUID quando aluno não encontrado
 * - Mensagem de boas-vindas automática
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
    console.log('[WEBHOOK-WAME v4.2] 📥 Webhook recebido - Versão Patch');
    const body = await req.json();
    // 🔥 LOG COMPLETO DO PAYLOAD RECEBIDO
    console.log('═══════════════════════════════════════');
    console.log('📦 PAYLOAD COMPLETO RECEBIDO:');
    // console.log(JSON.stringify(body, null, 2)); // Comentado para não poluir, descomente se precisar
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
              const mensagemBoasVindas = `👋 *Seja muito bem-vindo(a) ao ZapNutri, ${alunoByUuid.nome_completo}!*

A partir de agora, sua jornada fitness ficou muito mais simples e inteligente.

🎯 *Seu plano está pronto!*
Criamos seu Plano Alimentar e Programa de Treino personalizados. Acesse o app para visualizar todos os detalhes:
👉 https://zapnutri.app

🧠 *Pense em mim como sua equipe de elite 24 horas*
Imagine ter um Nutricionista Esportivo e um Personal Trainer morando no seu WhatsApp, prontos para te responder a qualquer momento.

Estou aqui para gerenciar sua rotina. Veja como posso te ajudar:

🍽️ *NO COMANDO DA DIETA*
- Dúvidas? "Quantas calorias tem esse prato?" ou "Posso comer isso agora?"
- Substituições Inteligentes: Faltou algum ingrediente? Me avise que eu calculo a troca perfeita com o que você tem em casa.
- Registro Automático: Terminou de comer? Apenas me diga "Comi meu café da manhã" e eu salvo tudo no seu histórico.

💪 *NO COMANDO DO TREINO*
- Execução e Dúvidas: Não sabe como fazer um exercício? É só perguntar.
- Check-in de Treino: Acabou a sessão? Me avise "Terminei o treino de hoje" para mantermos sua frequência em dia.
- Evolução de Cargas: Aumentou o peso no Supino? Me conte! Eu atualizo sua ficha para garantir sua progressão.

⚖️ *MONITORAMENTO*
- Se pesou? Me mande o valor que eu gero o gráfico da sua evolução.

Estou aqui para te orientar, ajustar a rota e garantir que você chegue no seu objetivo.

🚀 *Então, qual é o nosso primeiro passo de hoje? Refeição ou Treino?*`;
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
      // CASE 2 (LEGADO): messageContextInfo (Seu formato antigo)
      // ========================================
      case 'messageContextInfo':
        {
          console.log('[WEBHOOK-WAME] 🔘 Botão detectado (ContextInfo)');
          const buttonsResponse = data.msgContent?.buttonsResponseMessage;
          if (!buttonsResponse) {
            console.warn('[WEBHOOK-WAME] ⚠️ buttonsResponseMessage não encontrado');
            return new Response('ok: no button data', {
              headers: corsHeaders
            });
          }
          // Usa a função auxiliar para processar
          await processarAcaoBotao(supabase, buttonsResponse.selectedButtonId);
          break;
        }
      // ========================================
      // CASE 2.1 (NOVO): templateButtonReplyMessage (Android Novo)
      // ========================================
      case 'templateButtonReplyMessage':
        {
          console.log('[WEBHOOK-WAME] 🔘 Botão detectado (Template/Android)');
          const templateResponse = data.msgContent?.templateButtonReplyMessage;
          if (!templateResponse || !templateResponse.selectedId) {
            console.warn('[WEBHOOK-WAME] ⚠️ selectedId não encontrado no Template');
            return new Response('ok: no template data', {
              headers: corsHeaders
            });
          }
          // Usa a função auxiliar para processar
          await processarAcaoBotao(supabase, templateResponse.selectedId);
          break;
        }
      // ========================================
      // CASE 2.2 (NOVO): interactiveMessage (iPhone/Universal)
      // ========================================
      case 'interactiveMessage':
        {
          console.log('[WEBHOOK-WAME] 🔘 Botão detectado (Interactive)');
          const interactive = data.msgContent?.interactiveMessage;
          let selectedId = null;
          if (interactive?.nativeFlowResponseMessage) {
            try {
              const params = JSON.parse(interactive.nativeFlowResponseMessage.paramsJson);
              selectedId = params.id;
            } catch (e) {
              console.error('Erro parse native flow', e);
            }
          } else if (interactive?.listResponseMessage) {
            selectedId = interactive.listResponseMessage.singleSelectReply.selectedRowId;
          } else if (interactive?.buttonReplyMessage) {
            selectedId = interactive.buttonReplyMessage.selectedId;
          }
          if (!selectedId) {
            console.warn('[WEBHOOK-WAME] ⚠️ ID não encontrado no Interactive');
            return new Response('ok: no interactive id', {
              headers: corsHeaders
            });
          }
          // Usa a função auxiliar para processar
          await processarAcaoBotao(supabase, selectedId);
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
// FUNÇÃO AUXILIAR: PROCESSAR AÇÃO BOTÃO
// (Centraliza a lógica de confirmar/cancelar)
// ========================================
async function processarAcaoBotao(supabase, payloadString) {
  console.log('[PROCESSAR BOTÃO] 📋 Payload:', payloadString);
  // Parse do botão
  let buttonData;
  try {
    buttonData = JSON.parse(payloadString);
    console.log('[PROCESSAR BOTÃO] ✅ Parsed:', buttonData);
  } catch (parseError) {
    console.error('[PROCESSAR BOTÃO] ❌ Erro ao parsear JSON:', parseError);
    return;
  }
  const { action } = buttonData;
  console.log('[PROCESSAR BOTÃO] 🎯 Action:', action);
  if (action === 'resposta_botao') {
    console.log('[PROCESSAR BOTÃO] 🎯 Iniciando processamento');
    const { botao_id, confirmado } = buttonData;
    if (!botao_id) throw new Error('botao_id ausente');
    console.log('[PROCESSAR BOTÃO] 🔍 Buscando botão:', botao_id);
    // Buscar botão no banco
    const { data: botao, error: botaoErr } = await supabase.from('botoes_ativos').select('edge_function, tipo_acao').eq('id', botao_id).single();
    if (botaoErr || !botao) {
      console.error('[PROCESSAR BOTÃO] ❌ Botão não encontrado ou expirado:', botaoErr?.message);
      return; // Retorna silenciosamente para não travar o webhook
    }
    console.log('[PROCESSAR BOTÃO] ✅ Botão encontrado. Tipo:', botao.tipo_acao);
    console.log('[PROCESSAR BOTÃO] 🚀 Invocando Edge Function:', botao.edge_function);
    // Invocar edge function
    const { error: edgeError } = await supabase.functions.invoke(botao.edge_function, {
      body: {
        botao_id: botao_id,
        confirmado: confirmado
      }
    });
    if (edgeError) {
      console.error('[PROCESSAR BOTÃO] ❌ Erro na edge function:', edgeError);
      throw edgeError;
    }
    console.log('[PROCESSAR BOTÃO] ✅ Botão processado com sucesso!');
  } else {
    console.warn('[PROCESSAR BOTÃO] ⚠️ Action desconhecida:', action);
  }
}
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
