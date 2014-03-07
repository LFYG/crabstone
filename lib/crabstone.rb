# Library by Nguyen Anh Quynh
# Original binding by Nguyen Anh Quynh and Tan Sheng Di
# Additional binding work by Ben Nagy
# (c) 2013 COSEINC. All Rights Reserved.

require 'ffi'

require_relative 'arch/x86'
require_relative 'arch/x86_registers'
require_relative 'arch/arm'
require_relative 'arch/arm_registers'
require_relative 'arch/arm64'
require_relative 'arch/arm64_registers'
require_relative 'arch/mips'
require_relative 'arch/mips_registers'
require_relative 'arch/ppc'
require_relative 'arch/ppc_registers'

module Crabstone

  VERSION = '2.1.0'

  # Expected C version
  BINDING_MAJ = 2
  BINDING_MIN = 1

  ARCH_ARM   = 0
  ARCH_ARM64 = 1
  ARCH_MIPS  = 2
  ARCH_X86   = 3
  ARCH_PPC   = 4
  ARCH_ALL   = 0xFFFF
  SUPPORT_DIET = 0x10000

  MODE_LITTLE_ENDIAN = 0  # little endian mode (default mode)
  MODE_ARM           = 0  # 32-bit ARM
  MODE_16            = 1 << 1  # 16-bit mode
  MODE_32            = 1 << 2  # 32-bit mode
  MODE_64            = 1 << 3  # 64-bit mode
  MODE_THUMB         = 1 << 4 # ARM's Thumb mode, including Thumb-2
  MODE_MICRO         = 1 << 4 # MicroMips mode (MIPS architecture)
  MODE_N64           = 1 << 5 # Nintendo-64 mode (MIPS architecture)
  MODE_BIG_ENDIAN    = 1 << 31  # big endian mode

  # Option types and values ( so far ) for cs_option()
  OPT_SYNTAX = 1
  OPT_DETAIL = 2
  OPT_MODE   = 3

  SYNTAX = {
    :intel => 1,
    :att   => 2,
    :no_regname => 3 # for PPC only
  }

  DETAIL = {
    true  => 3, #trololol
    false => 0
  }

  class ErrArch < StandardError; end
  class ErrCsh < StandardError; end
  class ErrHandle < StandardError; end
  class ErrMem < StandardError; end
  class ErrMode < StandardError; end
  class ErrOK < StandardError; end
  class ErrOption < StandardError; end
  class ErrDetail < StandardError; end
  class ErrMemSetup < StandardError; end
  class ErrVersion < StandardError; end
  class ErrDiet < StandardError; end

  ERRNO = {
    0  => ErrOK,
    1  => ErrMem,
    2  => ErrArch,
    3  => ErrHandle,
    4  => ErrCsh,
    5  => ErrMode,
    6  => ErrOption,
    7  => ErrDetail,
    8  => ErrMemSetup,
    9  => ErrVersion,
    10 => ErrDiet
  }

  ERRNO_KLASS = ERRNO.invert

  def self.raise_errno errno
    err_klass = ERRNO[errno]
    raise RuntimeError, "Internal Error: Tried to raise unknown errno" unless err_klass
    err_str = Binding.cs_strerror(errno)
    raise err_klass, err_str
  end

  module Binding

    extend FFI::Library
    ffi_lib 'capstone'

    # This is because JRuby FFI on x64 Windows thinks size_t is 32 bit
    case FFI::Platform::ADDRESS_SIZE
    when 64
      typedef :ulong_long, :size_t
    when 32
      typedef :ulong, :size_t
    else
      fail "Unsupported native address size"
    end

    typedef :size_t, :csh
    typedef :size_t, :cs_opt_value
    typedef :uint, :cs_opt_type
    typedef :uint, :cs_err
    typedef :uint, :cs_arch
    typedef :uint, :cs_mode

    class Architecture < FFI::Union
      layout(
        :arm, ARM::Instruction,
        :arm64, ARM64::Instruction,
        :mips, MIPS::Instruction,
        :x86, X86::Instruction,
        :ppc, PPC::Instruction
      )
    end

    class Detail < FFI::Struct
      layout(
        :regs_read, [:uint8, 12],
        :regs_read_count, :uint8,
        :regs_write, [:uint8, 20],
        :regs_write_count, :uint8,
        :groups, [:uint8, 8],
        :groups_count, :uint8,
        :arch, Architecture
      )
    end

    class Instruction < FFI::Struct
      layout(
        :id, :uint,
        :address, :ulong_long,
        :size, :uint16,
        :bytes, [:uchar, 16],
        :mnemonic, [:char, 32],
        :op_str, [:char, 160],
        :detail, Detail.ptr
      )
    end

    attach_function(
      :cs_disasm_ex,
      [:csh, :pointer, :size_t, :ulong_long, :size_t, :pointer],
      :size_t
    )
    attach_function :cs_close, [:pointer], :cs_err
    attach_function :cs_errno, [:csh], :cs_err
    attach_function :cs_free, [:pointer, :size_t], :void
    attach_function :cs_insn_group, [:csh, Instruction, :uint], :bool
    attach_function :cs_insn_name, [:csh, :uint], :string
    attach_function :cs_op_count, [:csh, Instruction, :uint], :cs_err
    attach_function :cs_open, [:cs_arch, :cs_mode, :pointer], :cs_err
    attach_function :cs_option, [:csh, :cs_opt_type, :cs_opt_value], :cs_err
    attach_function :cs_reg_name, [:csh, :uint], :string
    attach_function :cs_reg_read, [:csh, Instruction, :uint], :bool
    attach_function :cs_reg_write, [:csh, Instruction, :uint], :bool
    attach_function :cs_version, [:pointer, :pointer], :uint
    attach_function :cs_support, [:cs_arch], :bool
    attach_function :cs_strerror, [:cs_err], :string

  end # Binding

  # This is a C engine build option, so we can set it here, not when we
  # instantiate a new Disassembler.
  DIET_MODE = Binding.cs_support SUPPORT_DIET
  # Diet mode means:
  # - No op_str or mnemonic in Instruction
  # - No regs_read, regs_write or groups ( even with detail on )
  # - No reg_name or insn_name id2str convenience functions
  # - detail mode CAN still be on - so the arch insn operands MAY be available

  class Instruction

    attr_reader :arch, :csh, :raw_insn

    ARCHS = {
      arm: ARCH_ARM,
      arm64: ARCH_ARM64,
      x86: ARCH_X86,
      mips: ARCH_MIPS,
      ppc: ARCH_PPC
    }.invert

    ARCH_CLASSES = {
      ARCH_ARM => ARM,
      ARCH_ARM64 => ARM64,
      ARCH_X86 => X86,
      ARCH_MIPS => MIPS,
      ARCH_PPC => PPC,
    }

    def initialize csh, insn, arch
      @arch       = arch
      @csh        = csh
      @raw_insn   = insn
      if detailed?
        @detail     = insn[:detail]
        @arch_insn  = @detail[:arch][ARCHS[arch]]
        @regs_read  = @detail[:regs_read].first( @detail[:regs_read_count] )
        @regs_write = @detail[:regs_write].first( @detail[:regs_write_count] )
        @groups     = @detail[:groups].first( @detail[:groups_count] )
      end
    end

    def name
      name = Binding.cs_insn_name(csh, id)
      Crabstone.raise_errno( ERRNO_KLASS[ErrCsh] ) unless name
      name
    end

    # It's more informative to raise if CS_DETAIL is off than just return nil
    def detailed?
      not @raw_insn[:detail].pointer.null?
    end

    def detail
      raise_unless_detailed
      @detail
    end

    def regs_read
      raise_unless_detailed
      raise_if_diet
      @regs_read
    end

    def regs_write
      raise_unless_detailed
      raise_if_diet
      @regs_write
    end

    def groups
      raise_unless_detailed
      raise_if_diet
      @groups
    end

    def group? groupid
      raise_unless_detailed
      raise_if_diet
      Binding.cs_insn_group csh, raw_insn, groupid
    end

    def reads_reg? reg
      raise_unless_detailed
      raise_if_diet
      Binding.cs_reg_read csh, raw_insn, ARCH_CLASSES[arch].register( reg )
    end

    def writes_reg? reg
      raise_unless_detailed
      raise_if_diet
      Binding.cs_reg_write csh, raw_insn, ARCH_CLASSES[arch].register( reg )
    end

    def mnemonic
      raise_if_diet
      raw_insn[:mnemonic]
    end

    def op_str
      raise_if_diet
      raw_insn[:op_str]
    end

    def op_count op_type=nil
      raise_unless_detailed
      if op_type
        Binding.cs_op_count csh, raw_insn, op_type
      else
        self.operands.size
      end
    end

    # So an Instruction should respond to all the methods in Instruction, and
    # all the methods in the Arch specific Instruction class. The methods /
    # members that have special handling for detail mode or diet mode are
    # handled above. The rest is dynamically dispatched below.
    def method_missing meth, *args
      if raw_insn.members.include? meth
        # Dispatch to toplevel Instruction class ( this file )
        raw_insn[meth]
      else
        # Nothing else is available with details.
        if not detailed?
          raise(
            NoMethodError,
            "Either CS_DETAIL is off, or #{self.class} doesn't implement #{meth}"
          )
        end
        # Dispatch to the architecture specific Instruction ( in arch/ )
        if @arch_insn.respond_to? meth
          @arch_insn.send meth, *args
        elsif @arch_insn.members.include? meth
          @arch_insn[meth]
        else
          raise NoMethodError, "Unknown method #{meth} for #{self.class}"
        end
      end
    end

    private

    def raise_unless_detailed
      Crabstone.raise_errno( Crabstone::ERRNO_KLASS[ErrDetail] ) unless detailed?
    end

    def raise_if_diet
      Crabstone.raise_errno( Crabstone::ERRNO_KLASS[ErrDiet] ) if DIET_MODE
    end

  end

  class Disassembly

    include Enumerable

    attr_reader :engine

    def initialize engine, code, offset, count=0
      @engine = engine
      @code = code
      @offset = offset
      @count = count
    end

    def each &blk
      begin

        insn       = Binding::Instruction.new
        insn_ptr   = FFI::MemoryPointer.new insn
        insn_count = Binding.cs_disasm_ex(
          engine.csh,
          @code,
          @code.bytesize,
          @offset,
          @count,
          insn_ptr
        )
        Crabstone.raise_errno(errno) if insn_count.zero?

        (0...insn_count * insn.size).step(insn.size).each {|insn_offset|
          cs_insn   = Binding::Instruction.new( (insn_ptr.read_pointer)+insn_offset )
          yield Instruction.new engine.csh, cs_insn, engine.arch
        }

      ensure
        Binding.cs_free insn_ptr.read_pointer, insn_count
      end
    end

    # Use of this method CAN BE LEAKY, please take care.
    def insns
      insn       = Binding::Instruction.new
      insn_ptr   = FFI::MemoryPointer.new insn
      insns = []
      insn_count = Binding.cs_disasm_ex(
        engine.csh,
        @code,
        @code.bytesize,
        @offset,
        @count,
        insn_ptr
      )
      Crabstone.raise_errno(errno) if insn_count.zero?
      cs_resources = [insn_ptr.read_pointer, insn_count]

      (0...insn_count * insn.size).step(insn.size).each {|insn_offset|
        cs_insn   = Binding::Instruction.new( (insn_ptr.read_pointer)+insn_offset )
        insns << Instruction.new( engine.csh, cs_insn, engine.arch )
      }
      # Once insns goes out of scope the underlying C memory will be freed.
      # HOWEVER, if you're still keeping a ref to any of the Instructions that
      # were inside that Array, they will still be valid, and will now behave
      # in an undefined manner, which might include segfaults, missing data,
      # or all kinds of other troubles.
      ObjectSpace.define_finalizer(insns) {Binding.cs_free(*cs_resources)}
      insns
    end

  end

  class Disassembler

    attr_reader :arch, :mode, :csh, :syntax, :decomposer

    def initialize arch, mode

      maj, min = version
      if maj != BINDING_MAJ || min != BINDING_MIN
        raise "FATAL: Binding for #{BINDING_MAJ}.#{BINDING_MIN}, found #{maj}.#{min}"
      end

      @arch    = arch
      @mode    = mode
      p_size_t = FFI::MemoryPointer.new :ulong_long
      @p_csh    = FFI::MemoryPointer.new p_size_t
      if ( res = Binding.cs_open( arch, mode, @p_csh )).nonzero?
        Crabstone.raise_errno res
      end

      @csh = @p_csh.read_ulong_long

    end

    # After you close the engine, don't use it anymore. Can't believe I even
    # have to write this.
    def close
      if ( res = Binding.cs_close(@p_csh) ).nonzero?
        Crabstone.raise_errno res
      end
    end

    def syntax= new_stx
      Crabstone.raise_errno( Crabstone::ERRNO_KLASS[ErrOption] ) unless SYNTAX[new_stx]
      res = Binding.cs_option(csh, OPT_SYNTAX, SYNTAX[new_stx])
      Crabstone.raise_errno res if res.nonzero?
      @syntax = new_stx
    end

    def decomposer= new_val
      res = Binding.cs_option(csh, OPT_DETAIL, DETAIL[!!(new_val)])
      Crabstone.raise_errno res if res.nonzero?
      @decomposer = !!(new_val)
    end

    def version
      maj = FFI::MemoryPointer.new(:int)
      min = FFI::MemoryPointer.new(:int)
      Binding.cs_version maj, min
      [ maj.read_int, min.read_int ]
    end

    def diet?
      DIET_MODE
    end

    def errno
      Binding.cs_errno(csh)
    end

    def reg_name regid
      Crabstone.raise_errno( Crabstone::ERRNO_KLASS[ErrDiet] ) if DIET_MODE
      name = Binding.cs_reg_name(csh, regid)
      Crabstone.raise_errno( Crabstone::ERRNO_KLASS[ErrCsh] ) unless name
      name
    end

    def disasm code, offset, count=0, &blk

      return [] if code.empty?
      Disassembly.new self, code, offset, count

    end

  end
end
