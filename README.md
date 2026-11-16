# Snapmark

Capturas de tela com anotações para macOS. Aperte **⌘⇧5**, selecione uma área e marque o que importa com setas, formas, texto ou borrão. Depois, copie ou salve.

É um app nativo, pequeno e sem dependências: um único arquivo Swift com AppKit. Fica na barra de menus e não aparece no Dock.

> **Status: alpha.** Funciona no uso diário, mas ainda tem arestas. Relatos de bugs são bem-vindos.

## Recursos

- **Captura de área** com ⌘⇧5. Na seleção, a barra de espaço alterna para captura de janela.
- **Editor de anotações**:

  | Ferramenta | Tecla |
  |---|---|
  | Seta | `A` |
  | Reta | `L` |
  | Retângulo | `R` |
  | Círculo / elipse | `O` |
  | Lápis (desenho livre) | `P` |
  | Marca-texto | `H` |
  | Borrar (pixeliza e desfoca) | `B` |
  | Texto | `T` |
  | Contador numerado (1, 2, 3…) | `N` |

- 8 cores prontas e seletor de cor personalizada, com 4 espessuras de traço.
- **Shift** trava retas e setas em ângulos de 45° e deixa retângulos e círculos com lados iguais.
- **⌘Z** desfaz e **⇧⌘Z** refaz. **Delete** apaga a última anotação.
- **⌘C** (ou Enter) copia para a área de transferência e fecha o editor. **⌘S** salva em PNG ou JPG.
- **Esc** fecha o editor e pede confirmação se houver anotações não salvas.
- Mantém a resolução Retina da captura.
- Abre imagens que já existem no editor (menu → *Abrir imagem no editor…*).
- Opção de iniciar junto com o sistema.

## Requisitos

- macOS 13 (Ventura) ou mais novo
- Apple Silicon ou Intel

## Instalação

### Pela release

1. Baixe o `.zip` mais recente em [Releases](https://github.com/lucas-azambuja/snapmark/releases).
2. Descompacte e mova o `Snapmark.app` para `/Applications`.
3. Abra o Snapmark. Um ícone de câmera aparece na barra de menus.

O app não é assinado com certificado de desenvolvedor da Apple, então o macOS bloqueia a primeira abertura. Para liberar, use uma destas opções:

- Tente abrir o app uma vez, vá em **Ajustes do Sistema → Privacidade e Segurança**, role até o aviso sobre o Snapmark e clique em **Abrir Mesmo Assim**.
- Ou rode no Terminal:
  ```bash
  xattr -d com.apple.quarantine /Applications/Snapmark.app
  ```

### Compilando o código

Precisa das Command Line Tools do Xcode (`xcode-select --install`).

```bash
git clone https://github.com/lucas-azambuja/snapmark.git
cd snapmark
./build.sh --install
```

## Configuração inicial

### 1. Liberar o atalho ⌘⇧5

O macOS usa ⌘⇧5 para a própria ferramenta de captura. Para o Snapmark receber o atalho, desligue o do sistema:

**Ajustes do Sistema → Teclado → Atalhos de Teclado… → Capturas de Tela →** desmarque **"Opções de captura de tela e gravação"**.

Se o atalho continuar ocupado, o menu do Snapmark mostra *"atalho ⌘⇧5 indisponível"*. A captura ainda funciona pelo menu.

### 2. Permitir a Gravação de Tela

Na primeira captura, o macOS pede a permissão de **Gravação de Tela**. Autorize o Snapmark e, se pedido, reabra o app.

Se a captura vier só com o papel de parede, a permissão não foi concedida. Confira em **Ajustes do Sistema → Privacidade e Segurança → Gravação de Tela**.

## Desenvolvimento

O código fica todo em [`Sources/main.swift`](Sources/main.swift). Não há projeto do Xcode: o `build.sh` chama o `swiftc` direto e monta o `.app`.

```bash
./build.sh                    # compila em build/Snapmark.app (binário universal)
./build.sh --run              # compila e roda sem instalar
./build.sh --run imagem.png   # compila e abre a imagem direto no editor
./build.sh --install          # compila e instala em /Applications
```

`--run imagem.png` é o caminho mais rápido para mexer no editor: não precisa capturar a tela nem dar permissão.

Só uma cópia do app consegue registrar o ⌘⇧5 por vez. Os modos `--run` e `--install` fecham qualquer Snapmark aberto antes de iniciar.

Como o app é assinado apenas localmente (ad-hoc), o macOS pode pedir a permissão de Gravação de Tela de novo depois de recompilar. Se isso acontecer, remova o Snapmark da lista em Privacidade e Segurança e autorize outra vez.

### Como funciona

- **Atalho global:** `RegisterEventHotKey` do Carbon, que não precisa de permissão de Acessibilidade.
- **Seleção de área:** usa o `screencapture -i` do próprio macOS.
- **Editor:** um `NSView` desenha a imagem e as anotações com Core Graphics. As anotações ficam em coordenadas de pixel da imagem, então a exportação sai na resolução original, não importa o zoom da janela.
- **Borrar:** Core Image (pixelização seguida de desfoque gaussiano), recortado na área marcada.

### Publicando uma release

1. Atualize o arquivo [`VERSION`](VERSION).
2. Escreva as notas em `release-notes/<versão>.md`.
3. Faça commit e rode `./release.sh`.

O script compila, gera o `.zip` com o checksum, cria e envia a tag `v<versão>` e publica a release com o [GitHub CLI](https://cli.github.com/). Versões com sufixo (como `0.1.0-alpha.0`) saem como pre-release.

## Limitações conhecidas

- Interface só em português.
- O atalho é fixo em ⌘⇧5.
- Anotações não podem ser selecionadas nem movidas depois de desenhadas.
- Não captura a tela inteira com atalho próprio, não grava vídeo e não faz OCR.

## Contribuindo

Issues e pull requests são bem-vindos. Para mudanças maiores, abra uma issue antes para conversarmos sobre a ideia.

## Licença

[MIT](LICENSE)
