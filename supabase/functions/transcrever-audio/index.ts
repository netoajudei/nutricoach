/**
 * @name transcrever-audio
 * @version 2.1.0 (Resiliente)
 * @description
 * Recebe o ID de uma mensagem temporária de áudio, busca os dados
 * do áudio (Base64), transcreve, atualiza a mensagem original
 * com o texto transcrito e aciona o `orquestrador-ia`.
 *
 * @param {object} body
 * @param {string} body.mensagem_id - ID da mensagem placeholder a ser processada.
 */ /**
 * @name transcrever-audio
 * @version 2.2.0 (Corrigido)
 * @description
 * Recebe o ID de uma mensagem de áudio, transcreve e aciona o orquestrador.
 *
 * @changelog
 * - v2.2.0: Corrigida a lógica de conversão de Base64 para Blob para
 * garantir que um arquivo válido seja enviado para a API da OpenAI,
 * resolvendo o erro "Expected UploadFile, received: <class 'str'>".
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js/+esm";
import { decode } from "https://deno.land/std@0.203.0/encoding/base64.ts"; // Importa o decodificador Base64 padrão do Deno
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
  const { mensagem_id } = await req.json();
  try {
    if (!mensagem_id) {
      throw new Error("Parâmetro `mensagem_id` é obrigatório.");
    }
    const supabase = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
    const { data: mensagem, error: fetchError } = await supabase.from('mensagens_temporarias').select('audio_base64').eq('id', mensagem_id).single();
    if (fetchError || !mensagem || !mensagem.audio_base64) {
      throw new Error(`Mensagem de áudio (ID: ${mensagem_id}) ou seus dados base64 não encontrados.`);
    }
    // --- CORREÇÃO AQUI ---
    // Converte a string Base64 para um array de bytes (Uint8Array) usando a biblioteca padrão do Deno.
    const audioBytes = decode(mensagem.audio_base64);
    // Cria um Blob a partir dos bytes. Este é o formato de arquivo correto.
    const audioBlob = new Blob([
      audioBytes
    ], {
      type: "audio/ogg"
    });
    const formData = new FormData();
    formData.append("file", audioBlob, "audio.ogg");
    formData.append("model", "whisper-1");
    const transcribeResponse = await fetch("https://api.openai.com/v1/audio/transcriptions", {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${Deno.env.get('OPENAI_API_KEY')}`
      },
      body: formData
    });
    if (!transcribeResponse.ok) {
      const errorText = await transcribeResponse.text();
      throw new Error(`Erro na API de transcrição: ${errorText}`);
    }
    const { text: transcribedText } = await transcribeResponse.json();
    console.log(`[Transcritor] Áudio da mensagem ${mensagem_id} transcrito: "${transcribedText}"`);
    const { error: updateError } = await supabase.from('mensagens_temporarias').update({
      mensagem: transcribedText,
      tipo: 'text',
      audio_base64: null
    }).eq('id', mensagem_id);
    if (updateError) throw new Error(`Erro ao atualizar a mensagem com o texto transcrito: ${updateError.message}`);
    await supabase.functions.invoke('orquestrador-ia', {
      body: {
        mensagem_id: mensagem_id
      }
    });
    return new Response(JSON.stringify({
      success: true,
      transcribedText: transcribedText
    }), {
      headers: {
        ...corsHeaders,
        'Content-Type': 'application/json'
      },
      status: 200
    });
  } catch (error) {
    console.error("🔥 Erro na função transcrever-audio:", error.message);
    if (mensagem_id) {
      const supabaseAdmin = createClient(Deno.env.get('SUPABASE_URL'), Deno.env.get('SUPABASE_SERVICE_ROLE_KEY'));
      await supabaseAdmin.from('mensagens_temporarias').update({
        mensagem: `[FALHA NA TRANSCRIÇÃO: ${error.message}]`
      }).eq('id', mensagem_id);
    }
    return new Response(JSON.stringify({
      error: error.message
    }), {
      status: 500,
      headers: corsHeaders
    });
  }
});
