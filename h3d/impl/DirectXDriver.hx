package h3d.impl;

import h3d.impl.Driver;
import dx.Driver;

private class ShaderContext {
	public var shader : Shader;
	public var globalsSize : Int;
	public var paramsSize : Int;
	public var globals : dx.Resource;
	public var params : dx.Resource;
	public function new(shader) {
		this.shader = shader;
	}
}

private class CompiledShader {
	public var vertex : ShaderContext;
	public var fragment : ShaderContext;
	public var layout : Layout;
	public function new() {
	}
}

class DirectXDriver extends h3d.impl.Driver {

	var driver : DriverInstance;
	var shaders : Map<Int,CompiledShader>;
	var box = new dx.Resource.ResourceBox();
	var buffers = new hl.NativeArray<dx.Resource>(16);
	var strides : Array<Int> = [];
	var zeroes : Array<Int> = [for( i in 0...16 ) 0];
	var currentShader : CompiledShader;
	var currentBuffer : dx.Resource;
	var currentIndex : dx.Resource;
	var defaultTarget : RenderTargetView;
	var currentTargets = new hl.NativeArray<RenderTargetView>(16);
	var viewport : hl.BytesAccess<hl.F32> = new hl.Bytes(6 * 4);
	var depthView : DepthStencilView;

	public function new() {
		shaders = new Map();
		var win = @:privateAccess dx.Window.windows[0];
		driver = Driver.create(win);
		if( driver == null ) throw "Failed to initialize DirectX driver";
		Driver.iaSetPrimitiveTopology(TriangleList);

		var width = win.width;
		var height = win.height;

		var depthDesc = new Texture2dDesc();
		depthDesc.width = width;
		depthDesc.height = height;
		depthDesc.format = D24_UNORM_S8_UINT;
		depthDesc.bind = DepthStencil;
		var depth = Driver.createTexture2d(depthDesc);
		depthView = Driver.createDepthStencilView(depth,depthDesc.format);

		var buf = Driver.getBackBuffer();
		defaultTarget = Driver.createRenderTargetView(buf);
		buf.release();

		viewport[2] = win.width;
		viewport[3] = win.height;
		viewport[5] = 1.;
		Driver.rsSetViewports(1, viewport);

		var desc = new DepthStencilStateDesc();
		desc.depthFunc = Less;
		desc.depthEnable = true;
		desc.depthWrite = true;
		var ds = Driver.createDepthStencilState(desc);
		Driver.omSetDepthStencilState(ds);

		currentTargets[0] = defaultTarget;
		Driver.omSetRenderTargets(1, currentTargets, depthView);


		var desc = new RasterizerStateDesc();
		desc.fillMode = Solid;
		desc.cullMode = None;
		desc.depthClipEnable = true;
		var rs = Driver.createRasterizerState(desc);
		Driver.rsSetState(rs);

		var desc = new SamplerStateDesc();
		var ss = Driver.createSamplerState(desc);
		var sarr = new hl.NativeArray(1);
		sarr[0] = ss;
		Driver.psSetSamplers(0, 1, sarr);
	}

	override function isDisposed() {
		return false;
	}

	override function init( onCreate : Bool -> Void, forceSoftware = false ) {
		haxe.Timer.delay(onCreate.bind(false), 1);
	}

	override function clear(?color:h3d.Vector, ?depth:Float, ?stencil:Int) {
		if( color != null )
			Driver.clearColor(currentTargets[0], color.r, color.g, color.b, color.a);
		if( depth != null || stencil != null )
			Driver.clearDepthStencilView(depthView, depth, stencil);
	}

	override function getDriverName(details:Bool) {
		var desc = "DirectX" + Driver.getSupportedVersion();
		if( details ) desc += " " + Driver.getDeviceName();
		return desc;
	}

	override function present() {
		Driver.present();
	}

	override function allocVertexes(m:ManagedBuffer):VertexBuffer {
		return dx.Driver.createBuffer(m.size * m.stride * 4, Default, VertexBuffer, None, None, 0, null);
	}

	override function allocIndexes( count : Int ) : IndexBuffer {
		return dx.Driver.createBuffer(count << 1, Default, IndexBuffer, None, None, 0, null);
	}

	override function allocTexture(t:h3d.mat.Texture):Texture {
		var desc = new Texture2dDesc();
		desc.width = t.width;
		desc.height = t.height;
		desc.format = R8G8B8A8_UNORM;
		desc.usage = Default;
		desc.bind = ShaderResource;
		var tex = Driver.createTexture2d(desc);
		return tex;
	}

	override function disposeTexture( t : h3d.mat.Texture ) {
		var tt = t.t;
		if( tt == null ) return;
		t.t = null;
		tt.release();
	}

	override function disposeVertexes(v:VertexBuffer) {
		v.release();
	}

	override function disposeIndexes(i:IndexBuffer) {
		i.release();
	}

	override function uploadIndexBuffer(i:IndexBuffer, startIndice:Int, indiceCount:Int, buf:hxd.IndexBuffer, bufPos:Int) {
		if( startIndice > 0 ) throw "!";
		i.updateSubresource(0, null, hl.Bytes.getArray(buf.getNative()).offset(bufPos<<1), 0, 0);
	}

	override function uploadIndexBytes(i:IndexBuffer, startIndice:Int, indiceCount:Int, buf:haxe.io.Bytes, bufPos:Int) {
		throw "TODO";
	}

	override function uploadVertexBuffer(v:VertexBuffer, startIndice:Int, indiceCount:Int, buf:hxd.FloatBuffer, bufPos:Int) {
		if( startIndice > 0 ) throw "!";
		v.updateSubresource(0, null, hl.Bytes.getArray(buf.getNative()).offset(bufPos<<2), 0, 0);
	}

	override function uploadVertexBytes(v:VertexBuffer, startIndice:Int, indiceCount:Int, buf:haxe.io.Bytes, bufPos:Int) {
		throw "TODO";
	}

	function compileShader( shader : hxsl.RuntimeShader.RuntimeShaderData, compileOnly = false ) {
		var h = new hxsl.HlslOut();
		var source = h.run(shader.data);
		var bytes = try dx.Driver.compileShader(source, "", "main", shader.vertex?"vs_5_0":"ps_5_0", WarningsAreErrors|OptimizationLevel3) catch( err : String ) {
			err = ~/^\(([0-9]+),([0-9]+)-([0-9]+)\)/gm.map(err, function(r) {
				var line = Std.parseInt(r.matched(1));
				var char = Std.parseInt(r.matched(2));
				var end = Std.parseInt(r.matched(3));
				return "\n<< " + source.split("\n")[line - 1].substr(char-1,end - char + 1) +" >>";
			});
			throw "Shader compilation error " + err + "\n\nin\n\n" + source;
		}
		if( compileOnly )
			return { s : null, bytes : bytes };
		var s = shader.vertex ? Driver.createVertexShader(bytes) : Driver.createPixelShader(bytes);
		if( s == null )
			throw "Failed to create shader\n" + source;
		var ctx = new ShaderContext(s);
		ctx.globalsSize = shader.globalsSize;
		ctx.paramsSize = shader.paramsSize;
		ctx.globals = dx.Driver.createBuffer(shader.globalsSize * 16, Dynamic, ConstantBuffer, CpuWrite, None, 0, null);
		ctx.params = dx.Driver.createBuffer(shader.paramsSize * 16, Dynamic, ConstantBuffer, CpuWrite, None, 0, null);
		return { s : ctx, bytes : bytes };
	}

	override function getNativeShaderCode( shader : hxsl.RuntimeShader ) {
		var v = compileShader(shader.vertex, true).bytes;
		var f = compileShader(shader.fragment, true).bytes;
		return Driver.disassembleShader(v, None, null) + "\n" + Driver.disassembleShader(f, None, null);
		//return "// vertex:\n" + new hxsl.HlslOut().run(shader.vertex.data) + "// fragment:\n" + new hxsl.HlslOut().run(shader.fragment.data);
	}

	override function selectShader(shader:hxsl.RuntimeShader) {
		var s = shaders.get(shader.id);
		if( s == null ) {
			s = new CompiledShader();
			var vertex = compileShader(shader.vertex);
			s.vertex = vertex.s;
			s.fragment = compileShader(shader.fragment).s;

			var layout = [];
			for( v in shader.vertex.data.vars )
				if( v.kind == Input ) {
					var e = new LayoutElement();
					e.semanticName = @:privateAccess v.name.toUtf8();
					e.format = switch( v.type ) {
					case TFloat: R32_FLOAT;
					case TVec(2, VFloat): R32G32_FLOAT;
					case TVec(3, VFloat): R32G32B32_FLOAT;
					case TVec(4, VFloat): R32G32B32A32_FLOAT;
					default:
						throw "Unsupported input type " + hxsl.Ast.Tools.toString(v.type);
					};
					e.inputSlotClass = PerVertexData;
					e.alignedByteOffset = -1; // automatic layout
					layout.push(e);
				}

			var n = new hl.NativeArray(layout.length);
			for( i in 0...layout.length )
				n[i] = layout[i];
			s.layout = Driver.createInputLayout(n, vertex.bytes, vertex.bytes.length);
			if( s.layout == null )
				throw "Failed to create input layout";
			shaders.set(shader.id, s);
		}
		if( s == currentShader )
			return false;
		currentShader = s;
		dx.Driver.vsSetShader(s.vertex.shader);
		dx.Driver.psSetShader(s.fragment.shader);
		dx.Driver.iaSetInputLayout(s.layout);
		return true;
	}

	override function selectBuffer(buffer:Buffer) {
		var vbuf = @:privateAccess buffer.buffer.vbuf;
		if( vbuf == currentBuffer )
			return;
		currentBuffer = vbuf;
		buffers[0] = vbuf;
		strides[0] = buffer.buffer.stride << 2;
		dx.Driver.iaSetVertexBuffers(0, 1, buffers, hl.Bytes.getArray(strides), hl.Bytes.getArray(zeroes));
		buffers[0] = null;
	}

	override function selectMultiBuffers(buffers:Buffer.BufferOffset) {
		throw "TODO";
	}

	function uploadShaderBuffer( sbuffer : dx.Resource, buffer : haxe.ds.Vector<hxd.impl.Float32>, size : Int ) {
		if( size == 0 ) return;
		var ptr = sbuffer.map(0, WriteDiscard, true);
		if( ptr == null ) throw "Can't map buffer " + sbuffer;
		ptr.blit(0, hl.Bytes.getArray(buffer.toData()), 0, size * 16);
		sbuffer.unmap(0);
	}

	override function uploadShaderBuffers(buffers:h3d.shader.Buffers, which:h3d.shader.Buffers.BufferKind) {
		switch( which ) {
		case Globals:
			uploadShaderBuffer(currentShader.vertex.globals, buffers.vertex.globals, currentShader.vertex.globalsSize);
			uploadShaderBuffer(currentShader.fragment.globals, buffers.fragment.globals, currentShader.fragment.globalsSize);
			this.buffers[0] = currentShader.vertex.globals;
			Driver.vsSetConstantBuffers(0, 1, this.buffers);
			this.buffers[0] = currentShader.fragment.globals;
			Driver.psSetConstantBuffers(0, 1, this.buffers);
		case Params:
			uploadShaderBuffer(currentShader.vertex.params, buffers.vertex.params, currentShader.vertex.paramsSize);
			uploadShaderBuffer(currentShader.fragment.params, buffers.fragment.params, currentShader.fragment.paramsSize);
			this.buffers[0] = currentShader.vertex.params;
			Driver.vsSetConstantBuffers(1, 1, this.buffers);
			this.buffers[0] = currentShader.fragment.params;
			Driver.psSetConstantBuffers(1, 1, this.buffers);
		case Textures:
		}
	}

	override function draw(ibuf:IndexBuffer, startIndex:Int, ntriangles:Int) {
		if( currentIndex != ibuf ) {
			currentIndex = ibuf;
			dx.Driver.iaSetIndexBuffer(ibuf,false,0);
		}
		dx.Driver.drawIndexed(ntriangles * 3, startIndex, 0);
	}

}