import * as vscode from 'vscode';
import * as net from 'net';
import * as os from 'os';
import * as path from 'path';

interface Config {
    autoReload: boolean;
    syncInterval: number;
    socketPath: string;
}

interface Position {
    line: number;
    character: number;
}

interface ViewState {
    cursor: Position;
    scroll: {
        topLine: number;
        bottomLine: number;
    };
}

interface TabInfo {
    path: string;
    active: boolean;
    viewState?: ViewState;
}

interface Message {
    type: 'editor_group' | 'buffer_change' | 'view_change';
    data: TabInfo[][] | { 
        path: string;
        viewState?: ViewState;
    };
    from_nvim?: boolean;
}

export class SyncManager {
    private config: Config;
    private client: net.Socket | null = null;
    private disposables: vscode.Disposable[] = [];
    private outputChannel: vscode.OutputChannel;
    private isHandlingNeovimMessage: boolean = false;
    private messageBuffer: string = '';  // 添加消息缓冲区

    constructor(config: Config) {
        this.config = this.normalizeConfig(config);
        this.outputChannel = vscode.window.createOutputChannel('Shadow Play');
        this.outputChannel.show();
        this.log('Shadow Play initialized');
    }

    private normalizeConfig(config: Config): Config {
        // Use workspace root directory if socketPath is not specified
        let socketPath = config.socketPath;
        if (!socketPath && vscode.workspace.workspaceFolders && vscode.workspace.workspaceFolders.length > 0) {
            socketPath = path.join(vscode.workspace.workspaceFolders[0].uri.fsPath, 'shadow-play.sock');
        }
        
        return {
            ...config,
            socketPath: socketPath ? socketPath.replace('~', os.homedir()) : ''
        };
    }

    public updateConfig(newConfig: Config): void {
        this.config = this.normalizeConfig(newConfig);
        this.restart();
    }

    public start(): void {
        this.connect();
    }

    private connect(): void {
        if (this.client) {
            return;
        }

        this.log('Connecting to Neovim...');
        this.client = net.createConnection(this.config.socketPath)
            .on('connect', () => {
                this.log('Connected to Neovim');
                this.syncEditorGroups();
            })
            .on('error', (err) => {
                this.log(`Connection error: ${err}`);
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            })
            .on('data', (data) => {
                // 将新数据添加到缓冲区
                this.messageBuffer += data.toString();
                
                // 处理所有完整的消息
                while (true) {
                    const nullIndex = this.messageBuffer.indexOf('\0');
                    if (nullIndex === -1) {
                        // 没有找到结束符，等待更多数据
                        break;
                    }
                    
                    // 提取一个完整的消息
                    const messageStr = this.messageBuffer.substring(0, nullIndex);
                    // 更新缓冲区，移除已处理的消息
                    this.messageBuffer = this.messageBuffer.substring(nullIndex + 1);
                    
                    if (!messageStr) continue;
                    
                    try {
                        this.log(`Received data: ${messageStr}`);
                        const message: Message = JSON.parse(messageStr);
                        this.handleMessage(message);
                    } catch (err) {
                        this.log(`Failed to parse message: ${err}`);
                    }
                }
            })
            .on('close', () => {
                this.log('Connection closed');
                this.client = null;
                this.messageBuffer = '';  // 清空缓冲区
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            });
    }

    private async handleMessage(message: Message): Promise<void> {
        this.log(`Handling message: ${message.type}`);
        this.isHandlingNeovimMessage = true;
        try {
            switch (message.type) {
                case 'editor_group':
                    await this.handleEditorGroupSync(message.data as TabInfo[][]);
                    break;
                case 'buffer_change':
                    await this.handleBufferChange(message.data as { path: string });
                    break;
                case 'view_change':
                    await this.handleViewChange(message.data as { path: string; viewState: ViewState });
                    break;
            }
        } finally {
            setTimeout(() => {
                this.isHandlingNeovimMessage = false;
            }, 100);
        }
    }

    private shouldIgnoreFile(filePath: string): boolean {
        // 忽略特殊文件
        const ignoredPatterns = [
            /^git:\/\/.*/,           // Git 协议文件
            /^untitled:.*/,          // 未命名文件
            /^output:.*/,            // 输出窗口
            /^extension-output-.*/,  // 扩展输出
            /^markdown-preview-.*/,  // Markdown 预览
            /^vscode-remote:.*/,     // VSCode 远程文件
            /^vscode-settings:.*/,   // VSCode 设置
            /^vscode-workspace:.*/,  // VSCode 工作区
            /^vscode-extension:.*/,  // VSCode 扩展
            /^vscode-.*/,            // 其他 VSCode 特殊文件
        ];

        return ignoredPatterns.some(pattern => pattern.test(filePath));
    }

    private async handleEditorGroupSync(groups: TabInfo[][]): Promise<void> {
        this.log(`Handling editor group sync with ${groups.length} groups`);
        
        // Get all active text editors
        const editors = vscode.window.visibleTextEditors
            .filter(editor => !this.shouldIgnoreFile(editor.document.uri.toString()));
            
        // Track which files we've processed
        const processedFiles = new Set<string>();
        
        // Process each group from Neovim
        for (let i = 0; i < groups.length; i++) {
            const group = groups[i];
            for (const buffer of group) {
                try {
                    // 忽略特殊文件
                    if (this.shouldIgnoreFile(buffer.path)) {
                        continue;
                    }

                    const uri = vscode.Uri.file(buffer.path);
                    processedFiles.add(uri.fsPath);
                    
                    // Check if file is already open
                    const isOpen = editors.some(editor => editor.document.uri.fsPath === uri.fsPath);
                    
                    if (!isOpen) {
                        this.log(`Opening new document: ${buffer.path}`);
                        // Open the document
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            viewColumn: i + 1 as vscode.ViewColumn,
                            preview: false,
                            preserveFocus: !buffer.active
                        });
                    } else if (buffer.active) {
                        this.log(`Activating existing document: ${buffer.path}`);
                        // Activate existing document if needed
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            viewColumn: i + 1 as vscode.ViewColumn,
                            preview: false,
                            preserveFocus: false
                        });
                    }
                } catch (error) {
                    this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                }
            }
        }
        
        // Close editors that are not in any group
        for (const editor of editors) {
            const uri = editor.document.uri;
            if (!processedFiles.has(uri.fsPath) && !this.shouldIgnoreFile(uri.toString())) {
                try {
                    await vscode.window.showTextDocument(editor.document, {
                        viewColumn: editor.viewColumn,
                        preview: true
                    });
                    await vscode.commands.executeCommand('workbench.action.closeActiveEditor');
                } catch (error) {
                    this.log(`Failed to close editor: ${error}`);
                }
            }
        }
    }

    private async handleBufferChange(data: { path: string }): Promise<void> {
        if (!this.config.autoReload) {
            return;
        }

        // 忽略特殊文件
        if (this.shouldIgnoreFile(data.path)) {
            return;
        }

        const uri = vscode.Uri.file(data.path);
        try {
            const doc = await vscode.workspace.openTextDocument(uri);
            await doc.save();
        } catch (err) {
            this.log(`Failed to reload document: ${err}`);
        }
    }

    private async handleViewChange(data: { path: string; viewState: ViewState }): Promise<void> {
        // 忽略特殊文件
        if (this.shouldIgnoreFile(data.path)) {
            return;
        }

        const uri = vscode.Uri.file(data.path);
        const editor = vscode.window.visibleTextEditors.find(
            editor => editor.document.uri.fsPath === uri.fsPath
        );

        if (editor) {
            this.log(`Updating view state for ${data.path}`);
            
            // Update cursor position
            const position = new vscode.Position(
                data.viewState.cursor.line,
                data.viewState.cursor.character
            );
            editor.selection = new vscode.Selection(position, position);

            // Update scroll position
            editor.revealRange(
                new vscode.Range(
                    data.viewState.scroll.topLine, 0,
                    data.viewState.scroll.bottomLine, 0
                ),
                vscode.TextEditorRevealType.InCenter
            );
        }
    }

    public syncEditorGroups(): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        const groups = this.getEditorGroupsInfo();
        this.sendMessage({
            type: 'editor_group',
            data: groups
        });
    }

    private getEditorGroupsInfo(): TabInfo[][] {
        const groups: TabInfo[][] = [];
        const visibleEditors = vscode.window.visibleTextEditors
            .filter(editor => !this.shouldIgnoreFile(editor.document.uri.toString()));

        // Group editors by their view column
        const editorsByColumn = new Map<number, vscode.TextEditor[]>();
        for (const editor of visibleEditors) {
            const column = editor.viewColumn || 1;
            if (!editorsByColumn.has(column)) {
                editorsByColumn.set(column, []);
            }
            editorsByColumn.get(column)!.push(editor);
        }

        // Convert each group to TabInfo[]
        for (const [column, editors] of editorsByColumn) {
            const groupTabs: TabInfo[] = [];
            for (const editor of editors) {
                const viewState = {
                    cursor: {
                        line: editor.selection.active.line,
                        character: editor.selection.active.character
                    },
                    scroll: {
                        topLine: editor.visibleRanges[0]?.start.line ?? 0,
                        bottomLine: editor.visibleRanges[0]?.end.line ?? 0
                    }
                };

                groupTabs.push({
                    path: editor.document.uri.fsPath,
                    active: editor === vscode.window.activeTextEditor,
                    viewState
                });
            }
            if (groupTabs.length > 0) {
                groups.push(groupTabs);
            }
        }

        return groups;
    }

    public syncBuffer(filePath: string): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        // 忽略特殊文件
        if (this.shouldIgnoreFile(filePath)) {
            return;
        }

        this.sendMessage({
            type: 'buffer_change',
            data: {
                path: filePath
            }
        });
    }

    public syncViewState(filePath: string): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        // 忽略特殊文件
        if (this.shouldIgnoreFile(filePath)) {
            return;
        }

        const editor = vscode.window.visibleTextEditors.find(
            e => e.document.uri.fsPath === filePath
        );

        if (editor) {
            this.sendMessage({
                type: 'view_change',
                data: {
                    path: filePath,
                    viewState: {
                        cursor: {
                            line: editor.selection.active.line,
                            character: editor.selection.active.character
                        },
                        scroll: {
                            topLine: editor.visibleRanges[0]?.start.line ?? 0,
                            bottomLine: editor.visibleRanges[0]?.end.line ?? 0
                        }
                    }
                }
            });
        }
    }

    private sendMessage(message: Message): void {
        if (!this.client) {
            return;
        }

        try {
            const messageStr = JSON.stringify(message) + '\0';
            this.log('Sending message: ' + messageStr);
            this.client.write(messageStr);
        } catch (err) {
            this.log('Failed to send message: ' + err);
        }
    }

    private restart(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        this.connect();
    }

    public dispose(): void {
        if (this.client) {
            this.client.end();
            this.client = null;
        }
        
        for (const disposable of this.disposables) {
            disposable.dispose();
        }
        this.disposables = [];
    }

    private log(message: string) {
        const timestamp = new Date().toISOString();
        this.outputChannel.appendLine(`[${timestamp}] ${message}`);
    }

    public isProcessingNeovimMessage(): boolean {
        return this.isHandlingNeovimMessage;
    }
} 