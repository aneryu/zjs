class A { static sm(){return 2} } class B extends A { static sx = super.sm(); } print(B.sx);
