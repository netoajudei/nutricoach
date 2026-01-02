/**
 * =================================================================================
 * ZAPNUTRI: UPLOAD DE MÍDIA (VERSÃO UUID / TABELA ALUNOS)
 * =================================================================================
 * Payload esperado (JSON):
 * {
 * "media_id": "...",       

 * "aluno_id": "a0eebc99...", <-- AGORA É STRING (UUID)
 * "categoria": "refeicao", 
 * "file_name": "foto.jpg",
 * "mime_type": "image/jpeg"
 * }
 * =================================================================================
 */ import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
serve(async (req)=>{
  try {
    // 1. CONFIGURAÇÕES (Variáveis de Ambiente do ZapNutri)
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const whatsappToken = Deno.env.get('META_ACCESS_TOKEN') ?? '' // <--- Token Meta definido nos Secrets
    ;
    if (!whatsappToken) {
      throw new Error("ERRO: 'META_ACCESS_TOKEN' não configurado nos Secrets.");
    }
    const supabase = createClient(supabaseUrl, supabaseKey);
    const body = await req.json();
    // 2. PAYLOAD LIMPO (Apenas dados do Aluno)
    const { media_id, aluno_id, file_name, mime_type, categoria } = body;
    if (!media_id || !aluno_id) {
      throw new Error("Faltam dados: media_id ou aluno_id.");
    }
    const pastaDestino = categoria ? categoria : 'geral';
    // =====================================================================
    // STEP 1: DOWNLOAD DO WHATSAPP (Meta API)
    // =====================================================================
    // Pega URL de download
    const responseGraph = await fetch(`https://graph.facebook.com/v18.0/${media_id}`, {
      headers: {
        'Authorization': `Bearer ${whatsappToken}`
      }
    });
    if (!responseGraph.ok) {
      const errText = await responseGraph.text();
      throw new Error(`Erro ao buscar mídia no Facebook: ${errText}`);
    }
    const dadosGraph = await responseGraph.json();
    const urlDownload = dadosGraph.url;
    // Baixa o arquivo (blob)
    const imageResponse = await fetch(urlDownload, {
      headers: {
        'Authorization': `Bearer ${whatsappToken}`
      }
    });
    if (!imageResponse.ok) throw new Error("Erro ao baixar o arquivo da URL temporária.");
    const fileBlob = await imageResponse.blob();
    // =====================================================================
    // STEP 2: UPLOAD NO STORAGE (Bucket: arquivos_alunos)
    // =====================================================================
    const BUCKET_NAME = 'arquivos_alunos';
    // Estrutura: UUID_DO_ALUNO / PASTA / TIMESTAMP.EXT
    const caminhoArquivo = `${aluno_id}/${pastaDestino}/${Date.now()}_${file_name || 'arquivo'}`;
    const { error: uploadError } = await supabase.storage.from(BUCKET_NAME).upload(caminhoArquivo, fileBlob, {
      contentType: mime_type || 'application/octet-stream',
      upsert: true
    });
    if (uploadError) throw new Error(`Erro no Storage: ${uploadError.message}`);
    // Gera URL Pública
    const { data: publicUrlData } = supabase.storage.from(BUCKET_NAME).getPublicUrl(caminhoArquivo);
    const urlFinal = publicUrlData.publicUrl;
    // =====================================================================
    // STEP 3: INSERT NA TABELA (galeria_alunos)
    // =====================================================================
    const { data: insertData, error: insertError } = await supabase.from('galeria_alunos').insert({
      aluno_id: aluno_id,
      url: urlFinal,
      tipo: pastaDestino,
      formato: mime_type
    }).select().single();
    if (insertError) throw new Error(`Erro ao salvar no banco: ${insertError.message}`);
    return new Response(JSON.stringify({
      success: true,
      message: "Mídia do aluno salva com sucesso!",
      arquivo: {
        id: insertData.id,
        url: urlFinal,
        tipo: pastaDestino
      }
    }), {
      status: 200,
      headers: {
        "Content-Type": "application/json"
      }
    });
  } catch (err) {
    return new Response(JSON.stringify({
      error: err.message
    }), {
      status: 500,
      headers: {
        "Content-Type": "application/json"
      }
    });
  }
});
