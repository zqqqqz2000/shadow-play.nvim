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

interface WindowLayout {
    type: 'leaf' | 'vsplit' | 'hsplit';
    buffers?: TabInfo[];
    children?: WindowLayout[];
    size?: number;
}

interface Message {
    type: 'editor_group' | 'buffer_change' | 'view_change';
    data: WindowLayout | { 
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
                    await this.handleEditorGroupSync(message.data as WindowLayout);
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

    private async handleEditorGroupSync(layout: WindowLayout): Promise<void> {
        this.log(`Handling window layout sync`);
        await this.applyWindowLayout(layout);
    }

    private async applyWindowLayout(layout: WindowLayout, viewColumn: vscode.ViewColumn = vscode.ViewColumn.One): Promise<void> {
        if (layout.type === 'leaf') {
            // 处理叶子节点
            for (const buffer of layout.buffers || []) {
                try {
                    if (this.shouldIgnoreFile(buffer.path)) {
                        continue;
                    }

                    const uri = vscode.Uri.file(buffer.path);
                    const doc = await vscode.workspace.openTextDocument(uri);
                    await vscode.window.showTextDocument(doc, {
                        viewColumn,
                        preview: false,
                        preserveFocus: !buffer.active
                    });

                    if (buffer.viewState) {
                        const editor = vscode.window.activeTextEditor;
                        if (editor && editor.document.uri.fsPath === uri.fsPath) {
                            const position = new vscode.Position(
                                buffer.viewState.cursor.line,
                                buffer.viewState.cursor.character
                            );
                            editor.selection = new vscode.Selection(position, position);
                            editor.revealRange(
                                new vscode.Range(
                                    buffer.viewState.scroll.topLine, 0,
                                    buffer.viewState.scroll.bottomLine, 0
                                ),
                                vscode.TextEditorRevealType.InCenter
                            );
                        }
                    }
                } catch (error) {
                    this.log(`Failed to handle buffer ${buffer.path}: ${error}`);
                }
            }
        } else {
            // 处理分割节点
            for (let i = 0; i < (layout.children || []).length; i++) {
                const child = layout.children![i];
                const nextColumn = layout.type === 'vsplit' 
                    ? viewColumn + i 
                    : viewColumn;
                await this.applyWindowLayout(child, nextColumn);
            }
        }
    }

    private getEditorGroupsInfo(): WindowLayout {
        const layout = this.buildWindowLayout(vscode.window.tabGroups.all);
        return layout || {
            type: 'leaf',
            buffers: []
        };
    }

    private buildWindowLayout(groups: readonly vscode.TabGroup[]): WindowLayout | null {
        if (groups.length === 0) {
            return null;
        }

        if (groups.length === 1) {
            // 单个组，创建叶子节点
            const buffers: TabInfo[] = [];
            for (const tab of groups[0].tabs) {
                if (!(tab.input instanceof vscode.TabInputText)) {
                    continue;
                }

                const editor = vscode.window.visibleTextEditors.find(
                    e => e.document.uri.fsPath === (tab.input as vscode.TabInputText).uri.fsPath
                    && e.viewColumn === groups[0].viewColumn  // 确保在同一个编辑器组
                );

                if (editor && !this.shouldIgnoreFile(editor.document.uri.toString())) {
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

                    buffers.push({
                        path: editor.document.uri.fsPath,
                        active: tab.isActive,  // 使用 tab 的激活状态
                        viewState
                    });
                }
            }

            return {
                type: 'leaf',
                buffers
            };
        }

        // TODO: 未来完善对嵌套布局的支持，目前简单处理为垂直分割
        const children: WindowLayout[] = [];
        for (const group of groups) {
            const child = this.buildWindowLayout([group]);
            if (child) {
                // 每个组占据相等的空间
                child.size = 1 / groups.length;
                children.push(child);
            }
        }

        return {
            type: 'vsplit',
            children
        };
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

        const layout = this.getEditorGroupsInfo();
        this.sendMessage({
            type: 'editor_group',
            data: layout
        });
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