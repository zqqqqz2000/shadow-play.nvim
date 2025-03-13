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
    type: 'tabs' | 'buffer_change' | 'view_change';
    data: TabInfo[][] | { 
        path: string;
        viewState?: ViewState;
    };
}

interface Logger {
    debug(message: string): void;
    info(message: string): void;
    warn(message: string): void;
    error(message: string): void;
}

export class SyncManager {
    private config: Config;
    private client: net.Socket | null = null;
    private disposables: vscode.Disposable[] = [];
    private logger: Logger;
    private outputChannel: vscode.OutputChannel;
    private isHandlingNeovimMessage: boolean = false;

    constructor(config: Config) {
        this.config = this.normalizeConfig(config);
        // Initialize logger
        this.logger = {
            debug: (message: string) => {
                if (vscode.workspace.getConfiguration('shadowPlay').get('debug')) {
                    console.log(`[DEBUG] ${message}`);
                }
            },
            info: (message: string) => console.log(`[INFO] ${message}`),
            warn: (message: string) => console.warn(`[WARN] ${message}`),
            error: (message: string) => console.error(`[ERROR] ${message}`)
        };
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
                this.syncTabs();
            })
            .on('error', (err) => {
                this.log(`Connection error: ${err}`);
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            })
            .on('data', (data) => {
                try {
                    this.log(`Received data: ${data.toString()}`);
                    const message: Message = JSON.parse(data.toString());
                    this.handleMessage(message);
                } catch (err) {
                    this.log(`Failed to parse message: ${err}`);
                }
            })
            .on('close', () => {
                this.log('Connection closed');
                this.client = null;
                // Try to reconnect after interval
                setTimeout(() => this.connect(), this.config.syncInterval);
            });
    }

    private async handleMessage(message: Message): Promise<void> {
        this.isHandlingNeovimMessage = true;
        try {
            switch (message.type) {
                case 'tabs':
                    await this.handleTabSync(message.data as TabInfo[][]);
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

    private async handleTabSync(tabs: TabInfo[][]): Promise<void> {
        this.logger.debug(`Handling tab sync with ${tabs.length} tabs`);
        
        // Get all active text editors
        const editors = vscode.window.tabGroups.all
            .flatMap(group => group.tabs)
            .filter(tab => tab.input instanceof vscode.TabInputText)
            .map(tab => (tab.input as vscode.TabInputText).uri);
            
        // Track which files we've processed
        const processedFiles = new Set<string>();
        
        // Process each tab from Neovim
        for (const tabInfo of tabs) {
            for (const buffer of tabInfo) {
                try {
                    // 忽略特殊文件
                    if (this.shouldIgnoreFile(buffer.path)) {
                        this.logger.debug(`Ignoring special file: ${buffer.path}`);
                        continue;
                    }

                    const uri = vscode.Uri.file(buffer.path);
                    processedFiles.add(uri.fsPath);
                    
                    // Check if file is already open
                    const isOpen = editors.some(editor => editor.fsPath === uri.fsPath);
                    
                    if (!isOpen) {
                        this.logger.debug(`Opening new document: ${buffer.path}`);
                        // Open the document
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            preview: false,
                            preserveFocus: !buffer.active
                        });
                    } else if (buffer.active) {
                        this.logger.debug(`Activating existing document: ${buffer.path}`);
                        // Activate existing document if needed
                        const doc = await vscode.workspace.openTextDocument(uri);
                        await vscode.window.showTextDocument(doc, {
                            preview: false,
                            preserveFocus: false
                        });
                    }
                } catch (error) {
                    this.logger.error(`Failed to handle buffer ${buffer.path}: ${error}`);
                }
            }
        }
        
        // Close tabs that are not in Neovim
        const tabsToClose = vscode.window.tabGroups.all
            .flatMap(group => group.tabs)
            .filter(tab => {
                if (!(tab.input instanceof vscode.TabInputText)) {
                    return false;
                }
                const uri = (tab.input as vscode.TabInputText).uri;
                // 忽略特殊文件
                if (this.shouldIgnoreFile(uri.toString())) {
                    return false;
                }
                return !processedFiles.has(uri.fsPath);
            });
            
        // Close tabs in reverse order to avoid index shifting
        for (const tab of tabsToClose.reverse()) {
            try {
                await vscode.window.tabGroups.close(tab);
            } catch (error) {
                this.logger.error(`Failed to close tab: ${error}`);
            }
        }
        
        this.logger.info('Tab synchronization completed');
    }

    private async handleBufferChange(data: { path: string }): Promise<void> {
        if (!this.config.autoReload) {
            return;
        }

        // 忽略特殊文件
        if (this.shouldIgnoreFile(data.path)) {
            this.logger.debug(`Ignoring buffer change for special file: ${data.path}`);
            return;
        }

        const uri = vscode.Uri.file(data.path);
        try {
            const doc = await vscode.workspace.openTextDocument(uri);
            await doc.save();
        } catch (err) {
            console.error('Failed to reload document:', err);
        }
    }

    private async handleViewChange(data: { path: string; viewState: ViewState }): Promise<void> {
        // 忽略特殊文件
        if (this.shouldIgnoreFile(data.path)) {
            this.logger.debug(`Ignoring view change for special file: ${data.path}`);
            return;
        }

        const uri = vscode.Uri.file(data.path);
        const editor = vscode.window.visibleTextEditors.find(
            editor => editor.document.uri.fsPath === uri.fsPath
        );

        if (editor) {
            this.logger.debug(`Updating view state for ${data.path}`);
            
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

    public syncTabs(): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        const tabs = this.getTabsInfo();
        this.sendMessage({
            type: 'tabs',
            data: tabs
        });
    }

    public syncBuffer(filePath: string): void {
        if (!this.client || this.isProcessingNeovimMessage()) {
            return;
        }

        // 忽略特殊文件
        if (this.shouldIgnoreFile(filePath)) {
            this.logger.debug(`Ignoring buffer sync for special file: ${filePath}`);
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
            this.logger.debug(`Ignoring view state sync for special file: ${filePath}`);
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

    private getTabsInfo(): TabInfo[][] {
        const tabs: TabInfo[][] = [];
        const groups = vscode.window.tabGroups.all;

        for (const group of groups) {
            const groupTabs: TabInfo[] = [];
            for (const tab of group.tabs) {
                const input = tab.input as vscode.TabInputText;
                if (input instanceof vscode.TabInputText) {
                    // 忽略特殊文件
                    if (this.shouldIgnoreFile(input.uri.toString())) {
                        continue;
                    }

                    const editor = vscode.window.visibleTextEditors.find(
                        e => e.document.uri.fsPath === input.uri.fsPath
                    );

                    const viewState = editor ? {
                        cursor: {
                            line: editor.selection.active.line,
                            character: editor.selection.active.character
                        },
                        scroll: {
                            topLine: editor.visibleRanges[0]?.start.line ?? 0,
                            bottomLine: editor.visibleRanges[0]?.end.line ?? 0
                        }
                    } : undefined;

                    groupTabs.push({
                        path: input.uri.fsPath,
                        active: tab === group.activeTab,
                        viewState
                    });
                }
            }
            if (groupTabs.length > 0) {
                tabs.push(groupTabs);
            }
        }

        return tabs;
    }

    private sendMessage(message: Message): void {
        if (!this.client) {
            return;
        }

        try {
            console.log('Sending message:', message);
            this.client.write(JSON.stringify(message));
        } catch (err) {
            console.error('Failed to send message:', err);
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