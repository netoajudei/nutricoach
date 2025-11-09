# Guia Completo: Comandos Supabase + Git

## 🚀 PARTE 1: SUPABASE CLI

### 1. Verificar e Configurar Supabase
```bash
# Verificar versão instalada
supabase --version

# Fazer login no Supabase
supabase login

# Fazer logout (trocar conta)
supabase logout
```

### 2. Gerenciar Projetos
```bash
# Listar todos os projetos
supabase projects list

# Vincular projeto local ao remoto
supabase link --project-ref SEU_PROJECT_ID
```

### 3. Backup da Estrutura do Banco
```bash
# Exportar estrutura do banco (sem dados)
supabase db dump --linked -f nome_do_arquivo.sql

# Exportar com project-ref específico
supabase db dump --project-ref SEU_PROJECT_ID -f nome_do_arquivo.sql
```

### 4. Gerenciar Edge Functions
```bash
# Listar todas as Edge Functions
supabase functions list --project-ref SEU_PROJECT_ID

# Baixar uma Edge Function específica
supabase functions download NOME_DA_FUNCAO --project-ref SEU_PROJECT_ID

# Exemplo:
supabase functions download waapi-webhook --project-ref ctsvfluufyfhkqlonqio
```

---

## 📁 PARTE 2: GIT E GITHUB

### 1. Configurar Git (Primeira Vez)
```bash
# Configurar nome de usuário
git config --global user.name "SEU_USERNAME"

# Configurar email
git config --global user.email "seu_email@exemplo.com"

# Ver configuração atual
git config --global user.name
git config --global user.email
```

### 2. Inicializar Repositório Local
```bash
# Entrar na pasta do projeto
cd /caminho/para/sua/pasta

# Inicializar Git
git init

# Adicionar todos os arquivos
git add .

# Fazer primeiro commit
git commit -m "Backup inicial do projeto"
```

### 3. Conectar ao GitHub
```bash
# Conectar ao repositório GitHub (HTTPS)
git remote add origin https://github.com/SEU_USERNAME/SEU_REPOSITORIO.git

# Conectar ao repositório GitHub (SSH)
git remote add origin git@github.com:SEU_USERNAME/SEU_REPOSITORIO.git

# Remover conexão (caso precise trocar)
git remote remove origin
```

### 4. Enviar para GitHub
```bash
# Primeiro push (criar branch main)
git push -u origin main

# Pushes subsequentes
git push
```

### 5. Workflow de Atualizações
```bash
# 1. Ver status dos arquivos
git status

# 2. Adicionar arquivos modificados
git add .

# 3. Fazer commit com mensagem
git commit -m "Descrição das mudanças"

# 4. Enviar para GitHub
git push
```

---

## 🔄 FLUXO COMPLETO DE BACKUP

### Cenário: Backup Completo de Projeto Supabase

```bash
# 1. Entrar na pasta do projeto
cd minha_pasta_projeto

# 2. Fazer login no Supabase
supabase login

# 3. Listar projetos
supabase projects list

# 4. Vincular projeto
supabase link --project-ref SEU_PROJECT_ID

# 5. Exportar estrutura do banco
supabase db dump --linked -f estrutura_banco.sql

# 6. Criar pasta para functions
mkdir edge_functions

# 7. Listar Edge Functions
supabase functions list --project-ref SEU_PROJECT_ID

# 8. Baixar cada Edge Function
supabase functions download NOME_FUNCAO --project-ref SEU_PROJECT_ID

# 9. Inicializar Git
git init

# 10. Adicionar tudo
git add .

# 11. Fazer commit
git commit -m "Backup completo - estrutura DB + Edge Functions"

# 12. Conectar ao GitHub
git remote add origin https://github.com/USERNAME/REPO.git

# 13. Enviar para GitHub
git push -u origin main
```

---

## 🔧 COMANDOS ÚTEIS EXTRAS

### Git
```bash
# Ver histórico de commits
git log --oneline

# Voltar para commit anterior
git checkout HASH_DO_COMMIT

# Voltar para a versão mais recente
git checkout main

# Ver diferenças antes do commit
git diff
```

### Supabase
```bash
# Executar com debug (para troubleshooting)
supabase db dump --debug --linked -f arquivo.sql

# Ver ajuda de qualquer comando
supabase help
supabase db dump --help
```

---

## 🚨 NOTAS IMPORTANTES

1. **Personal Access Token**: Para GitHub HTTPS, use Personal Access Token como senha
2. **SSH Keys**: Para SSH, configure chaves SSH no GitHub primeiro
3. **Project ID**: Sempre use o ID correto do projeto (coluna REFERENCE ID)
4. **Mensagens de Commit**: Use mensagens descritivas para facilitar o histórico
5. **Backup Regular**: Faça backups regulares após mudanças importantes