import Cocoa


class Super {
	static func shared() -> Self {
		self.init()
	}
	
	required init() {
		
	}
}

class SubA: Super {
	
}

class SubB: Super {
	
}

let subA = SubA.shared()
print(subA)
