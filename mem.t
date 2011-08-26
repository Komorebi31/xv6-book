.so book.mac
.ig
  terminology:
    process: refers to execution in user space, or maybe struct proc &c
    process memory: the lower part of the address space
    process's kernel thread
    so: swtch() switches to a given process's kernel thread
    trapret's iret switches to the process of the current
      kernel thread
  delete coalescing from kfree(), and associated text?
  talk a little about initial page table conditions:
    paging not on, but virtual mostly mapped direct to physical,
    which is what things look like when we turn paging on as well
    since paging is turned on after we create first process.
  mention why still have SEG_UCODE/SEG_UDATA?
  do we ever really say what the low two bits of %cs do?
    in particular their interaction with PTE_U
..
.chapter CH:MEM "Processes"
.PP
One of an operating system's central roles
is to allow multiple programs to share the processors
and main memory safely, isolating them so that
one errant program cannot break others.
To that end, xv6 provides the concept of a process,
as described in Chapter \*[CH:UNIX].
To run a program
.code sh
and 
.code wc ,
xv6 creates one process for each of them.
Each executes as if it has the computer to itself, and xv6
transparently multiplexes the computer resources between them.
For example, if the computer has one on more processors, xv6 will arrange that
each process will run periodically on one of the processors.
Furthermore, xv6 ensures that a bug in 
.code sh 
will not break 
.code wc .
That is, if 
.code sh
has a program error that causes it to write to an arbitrary memory location,
that wild write won't effect 
.code wc .
.PP
This chapter examines how xv6 allocates
memory to hold process code and data,
how it creates a new process,
and how it configures the processor's paging
hardware to give each process the illusion that
it has a private memory address space.
The next few chapters will examine how xv6 uses hardware
support for interrupts and context switching to create
the illusion that each process has its own private processor.
.\"
.section "Address Spaces"
.\"
.PP
xv6 ensures that each process can only read and write the memory that
xv6 has allocated to it, and not for example the kernel's memory or
the memory of other processes. xv6 also arranges for each process's
memory to be contiguous and to start at virtual address zero. The C
language definition and the Gnu linker expect process memory to be
contiguous. Process memory starts at zero because that is traditional.
A process's view of memory is called an
.italic "address space."
.PP
The xv6 boot loader has set up the segmentation hardware so that virtual and
physical addresses are always the same value: the segment descriptors
all have a base of zero and the maximum possible limit.
xv6 sets up the x86 paging hardware to translate (or "map") virtual to physical
addresses in a way that implements process address spaces with
the properties outlined in the previous paragraph.
.PP
The paging hardware uses a page table to translate virtual to
physical addresses. A page table is logically an array of 2^20
(1,048,576) page table entries (PTEs). Each PTE contains a
20-bit physical page number (PPN) and some flags. The paging
hardware translates a virtual address by using its top 20 bits
to index into the page table to find a PTE, and replacing
those bits with the PPN in the PTE.  The paging hardware
copies the low 12 bits unchanged from the virtual to the
translated physical address.  Thus a page table gives
the operating system control over virtual-to-physical address translations
at the granularity of aligned chunks of 4096 (2^12) bytes.
.so fig/x86_pagetable.t
.PP
On the x86, the translation from virtual to physical happens in two steps
(except when super pages are used, which we discuss below).
An x86 page table is stored in physical memory, in the form of a
4096-byte 
.italic "page directory" 
that contains 1024 PTE-like references to 
.italic "page table pages".
Each page table page is an array of 1024 32-bit PTEs.
The paging hardware uses the top 10 bits of a virtual address to
select a page directory entry.
If the page directory entry is present,
the paging hardware uses the next 10 bits of the virtual
address to select a PTE from the page table page that the
page directory entry refers to.
If either of the page directory entry or the PTE is not present,
the paging hardware raises a fault.
This two-level structure allows a page table to omit entire
page table pages in the common case in which large ranges of
virtual addresses have no mappings.
.PP
Each PTE contains flag bits that tell the paging hardware
to restrict how the associated virtual address is used.
.code PTE_P
indicates whether the PTE is present: if it is
not set, a reference to the page causes a fault (i.e. is not allowed).
.code PTE_W
controls whether instructions are allowed to issue
writes to the page; if not set, only reads and
instruction fetches are allowed.
.code PTE_U
controls whether user programs are allowed to use the
page; if clear, only the kernel is allowed to use the page.
Figure \n[pagetablefig] shows how it all works.
.PP
A few notes about terms.
Physical memory refers to storage cells in DRAM.
A byte of physical memory has an address, called a physical address.
A program uses virtual addresses, which the segmentation and
paging hardware translates to physical addresses, and then
sends to the DRAM hardware to read or write storage.
At this level of discussion there is no such thing as virtual memory,
only virtual addresses.
.\"
.section "Code: entry page table"
.\"
The boot loader has loaded the xv6 kernel into memory at physical address
.address 0x100000 ,
but the xv6 Makefile has linked the kernel at a high address, namely
.address 0xF0100000 .
The reason that the kernel is linked high is so that user programs can use the
low virtual addresses, from
.address 0, till
.address 0xF0100000 .
xv6 uses
.code KERNBASE 
(see
.file "memlayout.h"
.sheet memlayout.h )
to refer to this address.  We want such a large part of the address space for
user programs because we want to put the user stack high so that it can grow
down with plenty of space before it runs into the program's data structures.  We
would like to put the program text and data structures low so that they can
start at 0, a convenient convention.  We want to put the kernel and user program
in a single address space so that the kernel can easily transfer data from the
user program to the kernel, and back.   xv6 arrives at such an address space
layout in a few steps.
.PP
xv6 uses the paging hardware to arrange that the link address
.code KERNBASE ) (
maps to the load address, because any memory reference xv6 makes will use a high
address.  Thus, the first thing the 
.code entry
.line 'bootmain.c:/entry.=/'
does is setting up a page table for this mapping and enabling the paging
hardware so that it can enter the C part of the kernel.
The entry page table is defined 
in main.c
.line 'main.c:/enterpgdir/' .
It is 2^10 (1024) entries, instead of 2^20, because it takes advantage of 
.italic "super pages" , 
which are pages that are 4 Mbyte (2^22) large.  Entry 0 maps virtual address
.address 0
to
.address 0x400000
to physical address
.address 0
to 
.address 0x400000.
This part ensures that low addresses are mapped to low addresses; this is
important to do because the boot loader started running the kernel at low
addresses (e.g., the 
.code %eip
is set to 0x100020 ).
The pages are mapped as present
.code PTE_P
(present),
.code PTE_W
(writeable),
and
.code PTE_PS
(super page).
The flags and all other page hardware related structures are defined in
.file "mmu.h"
.sheet memlayout.h .
.PP
Entry 240
maps virtual address
.address 0xF0000000
to 
.address 0xF0400000
to physical address
.address 0
to 
.address 0x400000.
This entry ensures that the high are mapped to the physical addresses where the
kernel is loaded.  Thus, when the kernel starts to using high addresses, they
will map to the correct physical addresses.  Note that this mapping restricts
the kernel to the size of 4Mbyte, but that is sufficient for xv6.
.PP
Returning to
.code entry,
the kernel first tells the paging hardware to allow super pages by setting the flag
.code CR_PSE 
(page size extension) in the control register
.code %cr4.
Next it loads the physical address of
.code enterpgdir
into control register
.code %cr3.
The paging hardware must know the physical address of
.code pgdir, 
because it doesn't know how to translate virtual addresses yet; it doesn't have
a page table yet.
The macro
.code V2P_WO
.line 'memlayout.h:/V2P_WO/' 
computes the physical address.
To enable the paging hardware, xv6 sets the flags
.code CR0_PE|CR0_PG|CR0_WP
in the control register
.code %cr0.
.PP
After executing this instruction the processor increases 
.code %eip
to compute the address of the next instruction
and the paging hardware will translate that address.
Since we set up
.code entrypgdir
to translate low address one to one, this instructions will execute correctly.
If xv6 had omitted entry 0 from
.code entrypgdir,
the hardware could not have translated the address in
.code %eip
and it would stop executing instructions (i.e., the computer would crash).
.PP
Fortunately xv6 has set up the paging hardware correctly, and it loads
.code $relocated 
into
.code %eax.
The address
.code $relocated
is a high address. But, now xv6 has set up the paging hardware, it will translate
to a low physical address, where the value for 
.code $relocated
is actually located.
xv6 also loads a high address for the stack
into 
.code %esp;
the stack is located in low memory, but the paging hardware is set up.
Then, it calls
.code main,
which is also a high address.  The call will pushes the return address (a low
value!) on the stack.
After the call both
.code %eip
and
.code %esp
contain high values and the kernel is running in the high part of the virtual
address space.
.PP
The function
.code main 
initializes the kernel subsystems before it starts running user processes.  It
starts out by removing the mapping for the lower kernel virtual addresses, so
that it can use that part of the address space for user programs.  The function
.code kvmalloc
does so by setting up a new page table for the kernel (see
.code setupkvm )
and then switching to it  (see
.code switchkvm )
by loading into
.code %cr3 
the physical address of the new page table.
.\"
.section "A process's address space"
.\"
The function
.code setupkvm  
is not only invoked by xv6 during initialization, but every time xv6 creates a
new user process.   So, this is a good point to understand how xv6 uses the
paging hardware for isolating user processes.
.so fig/xv6_layout.t
.PP
Each process has a separate page table, and xv6 tells
the page table hardware to switch
page tables when xv6 switches between processes.
As shown in Figure \n[layoutfig],
a process's memory starts at virtual address
zero and can grow to the address
.address KERNBASE
(see
.file "memlayout.h"
.sheet memlayout.h ),
allowing for a 3,932,160 Kbyte user process.
xv6 sets up the PTEs for the process's virtual addresses to point
to whatever pages of physical memory xv6 has allocated for
the process's memory, and sets the 
.code PTE_U ,
.code PTE_W ,
and 
.code PTE_P
flags in these PTEs.
If a process has asked xv6 for less memory than
.address KERNBASE , 
xv6 will leave 
.code PTE_P
clear in the remainder of the PTEs.
.PP
Different processes' page tables translate the addresses till 
.address KERNBASE
to different pages of physical memory, so that each process has
private memory.
However, xv6 sets up every process's page table to translate virtual addresses
above
.address KERNBASE
in the same way.
It maps all the addresses from virtual address
.address KERNBASE
to 
.address KERNBASE+PHYSTOP
to
.address 0
to
.address PHYSTOP.
This allows the kernel to address all of physical memory.
However, xv6 does not set the
.code PTE_U
flag in the PTEs above
.address KERNBASE.
so only the kernel can use them.
For example, the kernel can use its own instructions and data
(at virtual addresses starting at 
.address KERNBASE+ 0x100000),
since the boot loader loaded the kernel al physical address 
.address 0x100000 , 
and the kernel maps
.address KERNBASE+ 0x100000
to 
.address 0x100000.
The reason that the kernel is at 
.address 0x100000
in physical memory is because the address range from
.address 0xa0000
(640 Kbyte)
till 
.address 0x100000
contains many older I/O devices.
The newer devices live in the device memory
at the top of the physical address space, starting
at 
.address 0xFE000000 .
The kernel can also read and write the physical memory beyond the end of its
data segment, where it allocates physical pages for user text, data, etc for a
process.  As mentioned above, xv6 maps these physical pages into the lower part
of the address space so that the user process can reference its own physical
memory (but not the physical pages of other processes).
.PP 
Every process's page table simultaneously contains
translations for both all of the process's memory and all
of the kernel's memory.
This setup allows system calls and interrupts to switch
between a running process and the kernel without
having to switch page tables.
For the most part the kernel does not have its own page
table; it is almost always borrowing some process's page table.
The price paid for this convenience is that the sum of the size
of the kernel and the largest process must be less than four
gigabytes on a machine with 32-bit addresses.
.PP
To review, xv6 ensures that each process can only use its own memory,
and that a process sees its memory as having contiguous virtual addresses.
xv6 implements the first by setting the
.code PTE_U
bit only on PTEs of virtual addresses that refer to the process's own memory.
It implements the second using the ability of page tables to translate
a virtual address to a different physical address.
.\"
.section "Code: creating an address space"
.\"
.PP
The function
.code setupkvm
sets up the kernel-part of an address space (i.e., starting from
.address KERNBASE )
allocates a page of memory (which we will discuss in the next subsection) to hold the page directory.
It then calls
.code mappages
to install translations for ranges of memory that the kernel
will use; these translations all map each virtual address to the
same physical address.  The translations include the kernel's
instructions and data, physical memory up to
.code PHYSTOP ,
and memory ranges which are actually I/O devices.
.code setupkvm
does not install any mappings for the process's memory;
this will happen later.
.PP
.code mappages
.line vm.c:/^mappages/
installs mappings into a page table
for a range of virtual addresses to
a corresponding range of physical addresses.
It does this separately for each virtual address in the range,
at page intervals.
For each virtual address to be mapped,
.code mappages
calls
.code walkpgdir
to find the address of the PTE that should the address's translation.
It then initializes the PTE to hold the relevant physical page
number, the desired permissions (
.code PTE_W
and/or
.code PTE_U ),
and 
.code PTE_P
to mark the PTE as valid
.line vm.c:/perm...PTE_P/ .
.PP
.code walkpgdir
.line vm.c:/^walkpgdir/
mimics the actions of the x86 paging hardware as it
looks up the PTE for a virtual address (see Fig. \n[pagetablefig]).
.code walkpgdir
uses the upper 10 bits of the virtual address to find
the page directory entry
.line vm.c:/pde.=..pgdir/ .
If the page directory entry isn't present, then
the required page table page hasn't yet been allocated;
if the
.code alloc
argument is set,
.code walkpgdir
goes ahead, allocates it, and puts its physical address in the page directory.
Finally it uses the next 10 bits of the virtual address
to find the address of the PTE in the page table page
.line vm.c:/return..pgtab/ .
.\"
.section "Memory allocation"
.\"
.PP
The functions
.code setupkvm
and
.code walkpgdir
allocate physical memory to hold the page directory and pages of the page table.
The kernel also needs to allocate physical to store processes' memory, and for
several kernel data structures.
The functions
.code setupkvm
and
.code walkpgdir
call a function 
.code alloc 
to allocate physical memory, but how it work?
There are three main questions to be answered when allocating
memory. First, what physical memory (i.e. DRAM storage cells) are to be used?
Second, at what virtual address or addresses is the newly allocated physical
memory to be mapped? And third, how does xv6 know what physical memory is free
and what memory is already in use?
.PP
xv6 maintains a pool of physical memory available for run-time allocation.  It
uses the physical memory beyond the end of the loaded kernel's data segment. xv6
allocates (and frees) physical memory at page (4096-byte) granularity. It keeps
a linked list of free physical pages; xv6 deletes newly allocated pages from the
list, and adds freed pages back to the list.  Note  that although we refer to this
memory pool as a pool of physical memory, the kernel addresses this memory using
virtual addresses.
.PP
What if a process allocates memory with
.code sbrk ?
Suppose that the current size of the process is 12 kilobytes,
and that xv6 finds a free page of physical memory at physical address
.address 0x601000,
which the kernel references using virtual address
.address 0xF0601000. 
In order to ensure that process memory remains contiguous,
that physical page should appear at virtual address 0x3000 when
the process is running.
This is the time (and the only time) when xv6 uses the paging hardware's
ability to translate a virtual address to a different physical address.
xv6 modifies the 3rd PTE (which covers virtual addresses 0x3000 through 0x3fff)
in the process's page table
to refer to physical page number 0x601 (the upper 20 bits of 0x601000),
and sets
.code PTE_U ,
.code PTE_W ,
and
.code PTE_P
in that PTE.
Now the process will be able to use 16 kilobytes of contiguous
memory starting at virtual address zero.
Two different PTEs now refer to the physical memory at 0x601000:
the PTE for virtual address 0xF0601000 and the PTE for virtual address
0x3000. The kernel can use both
addresses; the process can use only the second one.
.PP
There is a small bootstrap problem left: how does xv6 allocate memory before the
free list of physical memory is initialized?  One option is to initialize this
list immediately after the kernel starts, but the problem is that xv6 runs with
.code bootpgdir,
which maps only 4Mbyte of physical memory; at entry, xv6 cannot address all the
memory up to
.address PHYSTOP .
The other option is to set up the kernel address space to map all of physical
memory, but setting up that address space requires physical memory to allocate a
page for the page directory and to allocate pages for the page table pages.  xv6
solves this bootstrap problem by using a separate page allocator during entry,
which allocates memory right after the kernel's end of its data segment by just
moving the end of the data segment every time it needs a page.  This allocator
cannot allocate more than 4 Mbyte (including kernel image), but that is enough
physical memory to allocate a kernel page table.
.\"
.section "Code: Memory allocator"
.\"
.PP
During entry, the xv6 kernel calls
.code enter_alloc
to allocate physical memory while running with 
.code enterpgdir
as the address space.
This memory allocator moves the end of the kernel by 1 page.
.code enter_alloc
uses the symbol
.code end ,
which the linker causes to have an address that is just beyond
the end of the kernel's data segment.
A PTE can only refer to a physical address that is aligned
on a 4096-byte boundary (is a multiple of 4096), so
.code enter_alloc
uses
.code PGROUNDUP
to ensure that it allocates only aligned physical addresses.
The returned memory is never freed and so there is no corresponding call to free memory
allocated with 
.code enter_alloc .
.PP
Once the address space is setup, the xv6 kernel calls
.code kalloc
and
.code kfree
to allocate and free physical memory at run-time.
The kernel uses run-time allocation for process
memory and for these kernel data strucures:
kernel stacks, pipe buffers, and page tables.
The allocator manages page-sized (4096-byte) blocks of memory.
.PP
The allocator maintains a
.italic "free list" 
of addresses of physical memory pages that are available
for allocation.
Each free page's list element is a
.code struct
.code run 
.line kalloc.c:/^struct.run/ .
Where does the allocator get the memory
to hold that data structure?
It store each free page's
.code run
structure in the free page itself,
since there's nothing else stored there.
The free list is
protected by a spin lock 
.line kalloc.c:/^struct/,/}/ .
The list and the lock are wrapped in a struct
to make clear that the lock protects the fields
in the struct.
For now, ignore the lock and the calls to
.code acquire
and
.code release ;
Chapter \*[CH:LOCK] will examine
locking in detail.
.PP
The function
.code main
calls 
.code kinit
to initialize the allocator
.line kalloc.c:/^kinit/ .
.code kinit
ought to determine how much physical
memory is available, but this
turns out to be difficult on the x86.
Instead it assumes that the machine has
240 megabytes
.code PHYSTOP ) (
of physical memory, and uses all the memory between the end of the kernel
and 
.code PHYSTOP
as the initial pool of free memory.
.PP
The function
.code kinit
.line kalloc.c:/^kinit/
calls
.code kfree
with the address of each page of memory between
.code end
and
.code PHYSTOP .
This will cause
.code kfree
to add those pages to the allocator's free list.
The allocator starts with no memory;
these initial calls to
.code kfree
gives it some to manage.
.PP
The function
.code kfree
.line kalloc.c:/^kfree/
begins by setting every byte in the 
memory being freed to the value 1.
This will cause code that uses memory after freeing it
(uses "dangling references")
to read garbage instead of the old valid contents;
hopefully that will cause such code to break faster.
Then
.code kfree
casts
.code v 
to a pointer to
.code struct
.code run ,
records the old start of the free list in
.code r->next ,
and sets the free list equal to
.code r .
.code kalloc
removes and returns the first element in the free list.
.\"
.section "Code: Process creation"
.\"
.PP
This section describes how xv6 creates the very first process.
The xv6 kernel maintains many pieces of state for each process,
which it gathers into a
.code struct
.code proc
.line proc.h:/^struct.proc/ .
A process's most important pieces of kernel state are its 
page table and the physical memory it refers to,
its kernel stack, and its run state.
We'll use the notation
.code p->xxx
to refer to elements of the
.code proc
structure.
.PP
You should view the kernel state of a process as a thread
that executes in the kernel on behalf of a process.
For example, when a process makes a system call, the CPU
switches from executing the process to executing the
process's kernel thread.
The process's kernel thread executes the implementation
of the system call (e.g., reads a file), and then
returns back to the process.
.PP
.code p->pgdir
holds the process's page table, an array of PTEs.
xv6 causes the paging hardware to use a process's
.code p->pgdir
when executing that process.
A process's page table also serves as the record of the
addresses of the physical pages allocated to store the process's memory.
.PP
.code p->kstack
points to the process's kernel stack.
When a process's kernel thread is executing, for example in a system
call, it must have a stack on which to save variables and function
call return addresses.  xv6 allocates one kernel stack for each process.
The kernel stack is separate from the user stack, since the
user stack may not be valid.  Each process has its own kernel stack
(rather than all sharing a single stack) so that a system call may
wait (or "block") in the kernel to wait for I/O, and resume where it
left off when the I/O has finished; the process's kernel stack saves
much of the state required for such a resumption.
.PP
.code p->state 
indicates whether the process is allocated, ready
to run, running, waiting for I/O, or exiting.
.PP
The story of the creation of the first process starts when
.code main
.line main.c:/userinit/ 
calls
.code userinit
.line proc.c:/^userinit/ ,
whose first action is to call
.code allocproc .
The job of
.code allocproc
.line proc.c:/^allocproc/
is to allocate a slot
(a
.code struct
.code proc )
in the process table and
to initialize the parts of the process's state
required for its kernel thread to execute.
.code Allocproc 
is called for all new processes, while
.code userinit
is only called for the very first process.
.code Allocproc
scans the table for a process with state
.code UNUSED
.lines proc.c:/for.p.=.ptable.proc/,/goto.found/ .
When it finds an unused process, 
.code allocproc
sets the state to
.code EMBRYO
to mark it as used and
gives the process a unique
.code pid
.lines proc.c:/EMBRYO/,/nextpid/ .
Next, it tries to allocate a kernel stack for the
process's kernel thread.  If the memory allocation fails, 
.code allocproc
changes the state back to
.code UNUSED
and returns zero to signal failure.
.PP
Now
.code allocproc
must set up the new process's kernel stack.
Ordinarily processes are only created by
.code fork ,
so a new process
starts life copied from its parent.  The result of 
.code fork
is a child process
that has identical memory contents to its parent.
.code allocproc
sets up the child to 
start life running its kernel thread, with a specially prepared kernel
stack and set of kernel registers that cause it to "return" to user
space at the same place (the return from the
.code fork
system call) as the parent.
.code allocproc
does part of this work by setting up return program counter
values that will cause the new process's kernel thread to first execute in
.code forkret
and then in
.code trapret
.lines proc.c:/uint.trapret/,/uint.forkret/ .
The kernel thread will start executing
with register contents copied from
.code p->context .
Thus setting
.code p->context->eip
to
.code forkret
will cause the kernel thread to execute at
the start of 
.code forkret 
.line proc.c:/^forkret/ .
This function 
will return to whatever address is at the bottom of the stack.
The context switch code
.line swtch.S:/^swtch/
sets the stack pointer to point just beyond the end of
.code p->context .
.code allocproc
places
.code p->context
on the stack, and puts a pointer to
.code trapret
just above it; that is where
.code forkret
will return.
.code trapret
restores user registers
from values stored at the top of the kernel stack and jumps
into the process
.line trapasm.S:/^trapret/ .
This setup is the same for ordinary
.code fork
and for creating the first process, though in
the latter case the process will start executing at
location zero rather than at a return from
.code fork .
.PP
As we will see in Chapter \*[CH:TRAP],
the way that control transfers from user software to the kernel
is via an interrupt mechanism, which is used by system calls,
interrupts, and exceptions.
Whenever control transfers into the kernel while a process is running,
the hardware and xv6 trap entry code save user registers on the
top of the process's kernel stack.
.code userinit
writes values at the top of the new stack that
look just like those that would be there if the
process had entered the kernel via an interrupt
.lines proc.c:/tf..cs.=./,/tf..eip.=./ ,
so that the ordinary code for returning from
the kernel back to the process's user code will work.
These values are a
.code struct
.code trapframe
which stores the user registers.
Figure \n[newkernelstackfig] shows the state of the new process's kernel stack.
.so fig/newkernelstack.t
.PP
The first process is going to execute a small program
.code initcode.S ; (
.line initcode.S:1 ).
The process needs physical memory in which to store this
program, the program needs to be copied to that memory,
and the process needs a page table that refers to
that memory.
.PP
.code userinit
calls 
.code setupkvm
.line vm.c:/^setupkvm/
to create a page table for the process with (at first) mappings
only for memory that the kernel uses.  This function is the same one that the
kernel used to setup its page table.
.PP
The initial contents of the first process's memory are
the compiled form of
.code initcode.S ;
as part of the kernel build process, the linker
embeds that binary in the kernel and
defines two special symbols
.code _binary_initcode_start
and
.code _binary_initcode_size
telling the location and size of the binary
(XXX sidebar about why it is extern char[]).
.code Userinit
copies that binary into the new process's memory
by calling
.code inituvm ,
which allocates one page of physical memory,
maps virtual address zero to that memory,
and copies the binary to that page
.line vm.c:/^inituvm/ .
.PP
Then 
.code userinit
sets up the trap frame with the initial user mode state:
the
.code cs
register contains a segment selector for the
.code SEG_UCODE
segment running at privilege level
.code DPL_USER
(i.e., user mode not kernel mode),
and similarly
.code ds ,
.code es ,
and
.code ss
use
.code SEG_UDATA
with privilege
.code DPL_USER .
The
.code eflags
.code FL_IF
is set to allow hardware interrupts;
we will reexamine this in Chapter \*[CH:TRAP].
.PP
The stack pointer 
.code esp
is the process's largest valid virtual address,
.code p->sz .
The instruction pointer is the entry point
for the initcode, address 0.
Note that
.code initcode
is not an ELF binary and has no ELF header.
It is just a small headerless binary that expects
to run at address 0,
just as the boot loader is a small headerless binary
that expects to run at address
.code 0x7c00 .
.PP
.code Userinit
sets
.code p->name
to
.code "initcode"
mainly for debugging.
Setting
.code p->cwd
sets the process's current working directory;
we will examine
.code namei
in detail in Chapter \*[CH:FSDATA].
.\" TODO: double-check: is it FSDATA or FSCALL?  namei might move.
.PP
Once the process is initialized,
.code userinit
marks it available for scheduling by setting 
.code p->state
to
.code RUNNABLE .
.\"
.section "Code: Running a process"
.\"
Now that the first process's state is prepared,
it is time to run it.
After 
.code main
calls
.code userinit ,
.code mpmain
calls
.code scheduler
to start running processes
.line main.c:/scheduler/ .
.code Scheduler
.line proc.c:/^scheduler/
looks for a process with
.code p->state
set to
.code RUNNABLE ,
and there's only one it can find:
.code initproc .
It sets the per-cpu variable
.code proc
to the process it found and calls
.code switchuvm
to tell the hardware to start using the target
process's page table
.line vm.c:/lcr3.*p..pgdir/ .
Changing page tables while executing in the kernel
works because 
.code setupkvm
causes all processes' page tables to have identical
mappings for kernel code and data.
.code switchuvm
also creates a new task state segment
.code SEG_TSS
that instructs the hardware to handle
an interrupt by returning to kernel mode
with
.code ss
and
.code esp
set to
.code SEG_KDATA<<3
and
.code (uint)proc->kstack+KSTACKSIZE ,
the top of this process's kernel stack.
We will reexamine the task state segment in Chapter \*[CH:TRAP].
.PP
.code scheduler
now sets
.code p->state
to
.code RUNNING
and calls
.code swtch
.line swtch.S:/^swtch/ 
to perform a context switch to the target process's kernel thread.
.code swtch 
saves the current registers and loads the saved registers
of the target kernel thread
.code proc->context ) (
into the x86 hardware registers,
including the stack pointer and instruction pointer.
The current context is not a process but rather a special
per-cpu scheduler context, so
.code scheduler
tells
.code swtch
to save the current hardware registers in per-cpu storage
.code cpu->scheduler ) (
rather than in any process's kernel thread context.
We'll examine
.code switch
in more detail in Chapter \*[CH:SCHED].
The final
.code ret
instruction 
.line swtch.S:/ret$/
pops a new
.code eip
from the stack, finishing the context switch.
Now the processor is running the kernel thread of process
.code p .
.PP
.code Allocproc
set
.code initproc 's
.code p->context->eip
to
.code forkret ,
so the 
.code ret
starts executing
.code forkret .
On the first invocation (that is this one),
.code forkret
.line proc.c:/^forkret/
runs initialization functions that cannot be run from 
.code main 
because they must be run in the context of a regular process with its own
kernel stack. 
Then,
.code forkret
releases the 
.code ptable.lock
(see Chapter \*[CH:LOCK])
and then returns.
.code Allocproc
arranged that the top word on the stack after
.code p->context
is popped off
would be 
.code trapret ,
so now 
.code trapret
begins executing,
with 
.code %esp
set to
.code p->tf .
.code Trapret
.line trapasm.S:/^trapret/ 
uses pop instructions to walk
up the trap frame just as 
.code swtch
did with the kernel context:
.code popal
restores the general registers,
then the
.code popl 
instructions restore
.code %gs ,
.code %fs ,
.code %es ,
and
.code %ds .
The 
.code addl
skips over the two fields
.code trapno
and
.code errcode .
Finally, the
.code iret
instructions pops 
.code %cs ,
.code %eip ,
and
.code %eflags
off the stack.
The contents of the trap frame
have been transferred to the CPU state,
so the processor continues at the
.code %eip
specified in the trap frame.
For
.code initproc ,
that means virtual address zero,
the first instruction of
.code initcode.S .
.PP
At this point,
.code %eip
holds zero and
.code %esp
holds 4096.
These are virtual addresses in the process's address space.
The processor's paging hardware translates them into physical addresses
(we'll ignore segments since xv6 sets them up with the identity mapping
.line vm.c:/^seginit/ ).
.code allocuvm
set up the PTE for the page at virtual address zero to
point to the physical memory allocated for this process,
and marked that PTE with
.code PTE_U
so that the process can use it.
No other PTEs in the process's page table have the
.code PTE_U
bit set.
The fact that
.code userinit
.line proc.c:/UCODE/
set up the low bits of
.register cs
to run the process's user code at CPL=3 means that the user code
can only use PTE entries with
.code PTE_U
set, and cannot modify sensitive hardware registers such as
.register cr3 .
So the process is constrained to using only its own memory.
.PP
.code Initcode.S
.line initcode.S:/^start/
begins by pushing three values
on the stack—\c
.code $argv ,
.code $init ,
and
.code $0 —\c
and then sets
.code %eax
to
.code $SYS_exec
and executes
.code int
.code $T_SYSCALL :
it is asking the kernel to run the
.code exec
system call.
If all goes well,
.code exec
never returns: it starts running the program 
named by
.code $init ,
which is a pointer to
the NUL-terminated string
.code "/init"
.line initcode.S:/init.0/,/init.0/ .
If the
.code exec
fails and does return,
initcode
loops calling the
.code exit
system call, which definitely
should not return
.line initcode.S:/for.*exit/,/jmp.exit/ .
.PP
The arguments to the
.code exec
system call are
.code $init
and
.code $argv .
The final zero makes this hand-written system call look like the
ordinary system calls, as we will see in Chapter \*[CH:TRAP].  As
before, this setup avoids special-casing the first process (in this
case, its first system call), and instead reuses code that xv6 must
provide for standard operation.

.\"
.section "Exec"
.\"
As we saw in Chapter \*[CH:UNIX], 
.code exec
replaces the memory and registers of the
current process with a new program, but it leaves the
file descriptors, process id, and parent process the same.
.code Exec
is thus little more than a binary loader, just like the one 
in the boot loader from Chapter \*[CH:BOOT].
The additional complexity comes from setting up the stack.
.so fig/processlayout.t
.PP
Figure \n[processlayoutfig] shows the user memory image of an executing process.
The heap is above the stack so that it can expand (with
.code sbrk ).
The stack is a single page—4096 bytes—long.
Strings containing the command-line arguments, as well as an
array of pointers to them, are at the very top of the stack.
Just under that the kernel places values that allow a program
to start at
.code main
as if the function call
.code main(argc,
.code argv)
had just started.
The figure als shows the values that
.code exec
places at the top of the stack.
.\"
.section "Code: exec"
.\"
When the system call arrives (Chapter \*[CH:TRAP]
will explain how that happens),
.code syscall
invokes
.code sys_exec
via the 
.code syscalls
table
.line syscall.c:/static.int...syscalls/ .
.code Sys_exec
.line sysfile.c:/^sys_exec/
parses the system call arguments (also explained in Chapter \*[CH:TRAP]),
and invokes
.code exec
.line sysfile.c:/exec.path/ .
.PP
.code Exec
.line exec.c:/^exec/
opens the named binary 
.code path
using
.code namei
.line exec.c:/namei/ ,
which is explained in Chapter \*[CH:FSDATA],
and then reads the ELF header.
Like the boot loader, it uses
.code elf.magic
to decide whether the binary is an ELF binary
.line exec.c:/Check.ELF/,/ELF_MAGIC/+1 .
Then it allocates a new page table with no user mappings with
.code setupkvm
.line exec.c:/setupkvm/ ,
allocates memory for each ELF segment with
.code allocuvm
.line exec.c:/allocuvm/ ,
and loads each segment into memory with
.code loaduvm
.line exec.c:/loaduvm/ .
.code allocuvm
checks that the virtual addresses requested
is below
.address KERNBASE .
.code loaduvm
.line vm.c:/^loaduvm/
uses
.code walkpgdir
to find the physical address of the allocated memory at which to write
each page of the ELF segment, and
.code readi
to read from the file.
The ELF file may contain data segments that contain
global variables that should start out zero, represented with a
.code memsz
that is greater than the segment's
.code filesz ;
the result is that 
.code allocuvm
allocates zeroed physical memory, but
.code loaduvm
does not copy anything from the file.
.PP
Now
.code exec
allocates and initializes the user stack.
It assumes that one page of stack is enough.
If not,
.code copyout
will return \-1, as will 
.code exec .
.code Exec
first copies the argument strings to the top of the stack
one at a time, recording the pointers to them in 
.code ustack .
It places a null pointer at the end of what will be the
.code argv
list passed to
.code main .
The first three entries in 
.code ustack
are the fake return PC,
.code argc ,
and
.code argv
pointer.
.PP
During the preparation of the new memory image,
if 
.code exec
detects an error like an invalid program segment,
it jumps to the label
.code bad ,
frees the new image,
and returns \-1.
.code Exec
must wait to free the old image until it 
is sure that the system call will succeed:
if the old image is gone,
the system call cannot return \-1 to it.
The only error cases in
.code exec
happen during the creation of the image.
Once the image is complete, 
.code exec
can install the new image
.line exec.c:/switchuvm/
and free the old one
.line exec.c:/freevm/ .
Finally,
.code exec
returns 0.
Success!
.PP
Now the
.code initcode
.line initcode.S:1
is done.
.code Exec
has replaced it with the real
.code /init
binary, loaded out of the file system.
.code Init
.line init.c:/^main/
creates a new console device file
if needed
and then opens it as file descriptors 0, 1, and 2.
Then it loops,
starting a console shell, 
handles orphaned zombies until the shell exits,
and repeats.
The system is up.
.PP
Although the system is up, we skipped over some important subsystems of xv6.
The next chapter examines how xv6 configures the x86 hardware to handle the
system call interrupt caused by
.code int
.code $T_SYSCALL .
The rest of the book builds up enough of the process
management and file system implementation,
on which 
.code exec
relies.
.\"
.section "Real world"
.\"
.PP
Most operating systems have adopted the process
concept, and most processes look similar to xv6's.
A real operating system would find free
.code proc
structures with an explicit free list
in constant time instead of the linear-time search in
.code allocproc ;
xv6 uses the linear scan
(the first of many) for simplicity.
.PP
Like most operating systems, xv6 uses the paging hardware
for memory protection and mapping and mostly ignores
segmentation. Most operating systems make far more sophisticated
use of paging than xv6; for example, xv6 lacks demand
paging from disk, copy-on-write fork, shared memory,
and automatically extending stacks.
xv6 does use segments for the common trick of
implementing per-cpu variables such as
.code proc
that are at a fixed address but have different values
on different CPUs (see
.code seginit ).
Implementations of per-CPU (or per-thread) storage on non-segment
architectures would dedicate a register to holding a pointer
to the per-CPU data area, but the x86 has so few general
registers that the extra effort required to use segmentation
is worthwhile.
.PP
xv6's address space layout has some downsides.  For example, it is potentially
awkward for the kernel to map all of physical memory into the virtual address
space. This leave zero virtual address space for user mappings on a 32-bit
machine with 4 gigabytes of DRAM.
.PP
In the earliest days of operating systems,
each operating system was tailored to a specific
hardware configuration, so the amount of memory
could be a hard-wired constant.
As operating systems and machines became
commonplace, most developed a way to determine
the amount of memory in a system at boot time.
On the x86, there are at least three common algorithms:
the first is to probe the physical address space looking for
regions that behave like memory, preserving the values
written to them;
the second is to read the number of kilobytes of 
memory out of a known 16-bit location in the PC's non-volatile RAM;
and the third is to look in BIOS memory
for a memory layout table left as
part of the multiprocessor tables.
Reading the memory layout table
is complicated.
In the interest of simplicity, xv6 assumes
that the machine it runs on has at least 240 megabytes
of memory, and that it is all contiguous.
A real operating system would have to do a better job.
.PP
Memory allocation was a hot topic a long time ago, the basic problems being
efficient use of very limited memory and
preparing for unknown future requests.
See Knuth.  Today people care more about speed than
space-efficiency.  In addition, a more elaborate kernel
would likely allocate many different sizes of small blocks,
rather than (as in xv6) just 4096-byte blocks;
a real kernel
allocator would need to handle small allocations as well as large
ones.
.PP
.code Exec
is the most complicated code in xv6 in and in most operating systems.
It involves pointer translation
(in
.code sys_exec
too),
many error cases, and must replace one running process
with another.
Real world operationg systems have even more complicated
.code exec 
implementations.
They handle shell scripts (see exercise below),
more complicated ELF binaries, and even multiple
binary formats.
.\"
.section "Exercises"
.\"
1. Set a breakpoint at swtch.  Single step with gdb's
.code stepi
through the ret to
.code forkret ,
then use gdb's
.code finish
to proceed to
.code trapret ,
then
.code stepi
until you get to
.code initcode 
at virtual address zero.

2. Look at real operating systems to see how they size memory.

3. If xv6 had not used super pages, what would be the right declaration for
.code entrypgdir?

4. Unix implementations of 
.code exec
traditionally include special handling for shell scripts.
If the file to execute begins with the text
.code #! ,
then the first line is taken to be a program
to run to interpret the file.
For example, if
.code exec
is called to run
.code myprog
.code arg1
and
.code myprog 's
first line is
.code #!/interp ,
then 
.code exec
runs
.code /interp
with command line
.code /interp
.code myprog
.code arg1 .
Implement support for this convention in xv6.
