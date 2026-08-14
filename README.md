<img width="836" height="633" alt="image" src="https://github.com/user-attachments/assets/12b87c06-554d-48c9-9b25-7a96ab76c3cc" />


> >
>    𝐃𝐎 𝐘𝐎𝐔 𝐋𝐈𝐊𝐄 𝐆𝐑𝐄𝐄𝐍𝐄𝐑𝐈𝐄𝐒        你喜欢看绿油油的𝐒𝐜𝐡𝐞𝐦𝐚𝐭𝐢𝐜吗

>  RTL 文件 —— 本人独立设计  
>  测试文件 / 初始 hex / 说明文档 —— AI 辅助生成
> >
>  项目随进度更新

> “~我只是个搓绿化带的”
>  
  
  
自拟 6-bit 变长 ISA，29 条指令，支持控制、ALU、访存、IRET，RISC风格，目前仅实现整数集  
4 级流水线（IF/ID/EX/WB），两级前送+旁路消除 RAW 冒险，分支/中断 1 拍冲刷  
自拟 16 位总线，MMIO 挂载 RAM、UART（RX FIFO）、Timer、8 位可复用 GPIO  
硬件中断控制器，支持 4 路中断源（UART/Timer/GPIO1/2），向量表 + IRET 恢复断点  
硬件返回栈深 255 （非通用寄存器），满栈/空栈保护（JAL/JALR），flush 条件化  
支持HALT指令不可逆停机，rst初始化复位  
部分版本带有基于python的 asm to hex 汇编器（仅支持当版本）  
